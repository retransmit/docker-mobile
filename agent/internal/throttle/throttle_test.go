package throttle

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

func newClock() *clock { return &clock{t: time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)} }

func fail(l *Limiter, key string, n int) {
	for i := 0; i < n; i++ {
		l.Fail(key)
	}
}

func TestThresholdWindowAndPenaltiesInNumbers(t *testing.T) {
	if n := Threshold; n != 10 {
		t.Errorf("Threshold = %d, want 10", n)
	}
	for name, d := range map[string][2]time.Duration{
		"Window":      {Window, 10 * time.Minute},
		"BasePenalty": {BasePenalty, time.Minute},
		"MaxPenalty":  {MaxPenalty, 15 * time.Minute},
	} {
		if d[0] != d[1] {
			t.Errorf("%s = %v, want %v", name, d[0], d[1])
		}
	}
}

func TestNineFailuresDoNotBlock(t *testing.T) {
	l := New(newClock().now)
	fail(l, "10.0.0.1", Threshold-1)
	if _, blocked := l.Blocked("10.0.0.1"); blocked {
		t.Fatal("blocked below the threshold")
	}
}

func TestTheTenthFailureBlocksForAMinute(t *testing.T) {
	c := newClock()
	l := New(c.now)
	fail(l, "10.0.0.1", Threshold)
	left, blocked := l.Blocked("10.0.0.1")
	if !blocked || left != time.Minute {
		t.Fatalf("blocked = %v for %v, want a minute", blocked, left)
	}
	c.advance(59 * time.Second)
	if left, blocked := l.Blocked("10.0.0.1"); !blocked || left != time.Second {
		t.Fatalf("after 59 s: blocked = %v for %v", blocked, left)
	}
	c.advance(time.Second)
	if _, blocked := l.Blocked("10.0.0.1"); blocked {
		t.Fatal("still blocked after the minute")
	}
}

func TestThePenaltyDoublesAndIsCapped(t *testing.T) {
	c := newClock()
	l := New(c.now)
	fail(l, "a", Threshold)
	want := []time.Duration{2 * time.Minute, 4 * time.Minute, 8 * time.Minute, 15 * time.Minute, 15 * time.Minute}
	for i, w := range want {
		l.Fail("a")
		if left, _ := l.Blocked("a"); left != w {
			t.Fatalf("failure %d: penalty = %v, want %v", Threshold+1+i, left, w)
		}
	}
}

func TestABlockNeverGetsShorter(t *testing.T) {
	c := newClock()
	l := New(c.now)
	fail(l, "a", Threshold+4) // 15 minutes
	c.advance(Window)         // the failures left the window, the block has 5 minutes to go
	before, _ := l.Blocked("a")
	if before != 5*time.Minute {
		t.Fatalf("%v of the block left after the window, want 5 minutes", before)
	}
	fail(l, "a", Threshold) // by themselves these ten are worth a minute
	if after, _ := l.Blocked("a"); after < before {
		t.Fatalf("ten more failures cut the block from %v to %v", before, after)
	}
}

func TestAddressesAreCountedSeparately(t *testing.T) {
	l := New(newClock().now)
	fail(l, "a", Threshold)
	if _, blocked := l.Blocked("b"); blocked {
		t.Fatal("another address is blocked")
	}
	if _, blocked := l.Blocked("never-seen"); blocked {
		t.Fatal("an unknown address is blocked")
	}
}

func TestFailuresLeaveTheWindow(t *testing.T) {
	c := newClock()
	l := New(c.now)
	fail(l, "a", Threshold-1)
	c.advance(Window)
	l.Fail("a")
	if _, blocked := l.Blocked("a"); blocked {
		t.Fatal("failures older than the window still count")
	}
	fail(l, "a", Threshold-1)
	if _, blocked := l.Blocked("a"); !blocked {
		t.Fatal("ten failures inside the window did not block")
	}
}

func TestTheWindowIsTenMinutesToTheNanosecond(t *testing.T) {
	c := newClock()
	l := New(c.now)
	fail(l, "just-inside", 9)
	c.advance(10*time.Minute - time.Nanosecond)
	l.Fail("just-inside")
	if _, blocked := l.Blocked("just-inside"); !blocked {
		t.Error("nine failures a nanosecond inside the window and a tenth did not block")
	}

	fail(l, "just-outside", 9)
	c.advance(10 * time.Minute)
	l.Fail("just-outside")
	if _, blocked := l.Blocked("just-outside"); blocked {
		t.Error("nine failures exactly ten minutes old and a tenth blocked")
	}
}

func TestFailuresAtDifferentTimesAddUp(t *testing.T) {
	c := newClock()
	l := New(c.now)
	for i := 1; i <= 10; i++ {
		l.Fail("a")
		left, blocked := l.Blocked("a")
		if blocked != (i == 10) {
			t.Fatalf("one failure a minute, after failure %d: blocked = %v", i, blocked)
		}
		if blocked && left != time.Minute {
			t.Fatalf("the tenth failure blocks for %v, want a minute", left)
		}
		c.advance(time.Minute)
	}
}

func TestOneAddressKeepsOnlyItsNewestFailures(t *testing.T) {
	c := newClock()
	l := New(c.now)
	for i := 0; i < 5000; i++ {
		c.advance(time.Millisecond)
		l.Fail("a")
	}
	kept := l.addrs["a"].failures
	if n := len(kept); n != Threshold+4 {
		t.Fatalf("%d failure times kept for one address, want %d", n, Threshold+4)
	}
	if newest, oldest := kept[len(kept)-1], kept[0]; !newest.Equal(c.now()) || c.now().Sub(oldest) != 13*time.Millisecond {
		t.Fatalf("kept the times from %v to %v, want the newest ones up to %v", oldest, newest, c.now())
	}
	if left, blocked := l.Blocked("a"); !blocked || left != MaxPenalty {
		t.Fatalf("blocked = %v for %v, want %v", blocked, left, MaxPenalty)
	}
}

func TestKeyDropsThePort(t *testing.T) {
	cases := map[string]string{
		"192.168.1.5:51234":                      "192.168.1.5",
		"192.0.2.7:51234":                        "192.0.2.7",
		"[::ffff:192.0.2.7]:1":                   "192.0.2.7",
		"[2001:db8:1:2:aaaa:bbbb:cccc:dddd]:443": "2001:db8:1:2::/64",
		"[2001:db8:1:2::1]:443":                  "2001:db8:1:2::/64",
		"[2001:db8:1:3::1]:443":                  "2001:db8:1:3::/64",
		"[::1]:8443":                             "::/64",
		"[fe80::1%eth0]:1":                       "fe80::/64%eth0",
		"[fe80::2%eth0]:1":                       "fe80::/64%eth0",
		"[fe80::1%wlan0]:1":                      "fe80::/64%wlan0",
		"example.com:80":                         "example.com",
		"not-an-address":                         "not-an-address",
		"no-port":                                "no-port",
		"":                                       "",
	}
	for in, want := range cases {
		if got := Key(in); got != want {
			t.Errorf("Key(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestMemoryIsBounded(t *testing.T) {
	c := newClock()
	l := New(c.now)
	for i := 0; i < maxAddresses; i++ {
		l.Fail(fmt.Sprintf("addr-%d", i))
		if i%1000 == 0 {
			c.advance(time.Second)
		}
	}
	// Everything so far is still inside the window: the oldest ones go.
	l.Fail("one-more")
	if n := len(l.addrs); n > maxAddresses {
		t.Fatalf("%d addresses remembered, cap is %d", n, maxAddresses)
	}
	if _, ok := l.addrs["addr-0"]; ok {
		t.Fatal("the oldest address was not dropped")
	}
	// Once the window has passed, a full table drops everything forgettable
	// at once.
	for i := 0; len(l.addrs) < maxAddresses; i++ {
		l.Fail(fmt.Sprintf("more-%d", i))
	}
	c.advance(Window)
	l.Fail("after-the-window")
	if n := len(l.addrs); n != 1 {
		t.Fatalf("%d addresses remembered after the window, want 1", n)
	}
}

func TestTheTableStaysWithinItsCapAlsoWithAnEmptyKey(t *testing.T) {
	c := newClock()
	l := New(c.now)
	l.Fail("") // the oldest entry of all
	c.advance(time.Second)
	for i := 0; i < 2*maxAddresses; i++ {
		l.Fail(fmt.Sprintf("addr-%d", i))
		if n := len(l.addrs); n > maxAddresses {
			t.Fatalf("%d addresses remembered after %d more, cap is %d", n, i+1, maxAddresses)
		}
	}
	if _, ok := l.addrs[""]; ok {
		t.Fatal("the oldest address was kept because its key is empty")
	}
}

func TestMakingRoomFreesATenthOfTheTableAtOnce(t *testing.T) {
	c := newClock()
	l := New(c.now)
	for i := 0; i < maxAddresses; i++ {
		l.Fail(fmt.Sprintf("addr-%d", i))
	}
	// The table is full and nothing in it can be forgotten. A pass frees a
	// tenth of it; until that room is used up the table grows by exactly one
	// per new address, which shows that no pass ran in between.
	batch := maxAddresses / 10
	passes := 0
	for i := 0; i < 3*batch; i++ {
		before := len(l.addrs)
		l.Fail(fmt.Sprintf("new-%d", i))
		switch after := len(l.addrs); {
		case after == before+1:
		case before == maxAddresses && after == maxAddresses-batch+1:
			passes++
		default:
			t.Fatalf("new address %d: the table went from %d to %d", i+1, before, after)
		}
	}
	if passes != 3 {
		t.Fatalf("%d passes for %d new addresses, want 3", passes, 3*batch)
	}
}

func TestABlockedAddressIsNotForgottenWhileBlocked(t *testing.T) {
	c := newClock()
	l := New(c.now)
	fail(l, "attacker", Threshold+4) // 15 minutes
	c.advance(Window)                // failures left the window, the block has not ended
	for i := 0; i < maxAddresses; i++ {
		l.Fail(fmt.Sprintf("addr-%d", i))
	}
	if _, blocked := l.Blocked("attacker"); !blocked {
		t.Fatal("a blocked address was forgotten")
	}
}

func TestAddressesThatAreNotBlockedGoBeforeBlockedOnes(t *testing.T) {
	c := newClock()
	l := New(c.now)
	const blockedOnes = 5
	for i := 0; i < blockedOnes; i++ {
		fail(l, fmt.Sprintf("blocked-%d", i), Threshold+4) // 15 minutes
	}
	c.advance(time.Minute) // every other address failed later than the blocked ones
	for i := 0; len(l.addrs) < maxAddresses; i++ {
		l.Fail(fmt.Sprintf("addr-%d", i))
	}
	l.Fail("one-more")
	if n, want := len(l.addrs), maxAddresses-maxAddresses/10+1; n != want {
		t.Fatalf("%d addresses remembered after making room, want %d", n, want)
	}
	for i := 0; i < blockedOnes; i++ {
		if _, blocked := l.Blocked(fmt.Sprintf("blocked-%d", i)); !blocked {
			t.Fatalf("blocked address %d was forgotten while others could go", i)
		}
	}
}

func TestWhenEveryAddressIsBlockedTheBlocksThatEndSoonestGoFirst(t *testing.T) {
	c := newClock()
	l := New(c.now)
	// The first addresses failed longest ago but are blocked for 15 minutes.
	// The others are blocked for a minute, each a millisecond later than the
	// one before it.
	const long = 500
	for i := 0; i < maxAddresses; i++ {
		n := Threshold
		if i < long {
			n = Threshold + 4
		}
		fail(l, fmt.Sprintf("addr-%d", i), n)
		c.advance(time.Millisecond)
	}
	l.Fail("one-more")
	batch := maxAddresses / 10
	for i := 0; i < maxAddresses; i++ {
		_, kept := l.addrs[fmt.Sprintf("addr-%d", i)]
		if want := i < long || i >= long+batch; kept != want {
			t.Fatalf("address %d: kept = %v, want %v", i, kept, want)
		}
	}
}

func TestTheLimiterHoldsUnderConcurrentCalls(t *testing.T) {
	c := newClock()
	l := New(c.now)
	const goroutines = 8
	const each = maxAddresses / 4 // twice the cap of distinct keys in all
	var wg sync.WaitGroup
	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			wrong := 0
			for i := 0; i < each; i++ {
				l.Fail("shared")
				// This goroutine alone has now failed i+1 times on the shared key.
				if _, blocked := l.Blocked("shared"); !blocked && i+1 >= Threshold {
					wrong++
				}
				own := fmt.Sprintf("g%d-%d", g, i)
				l.Fail(own)
				if _, blocked := l.Blocked(own); blocked {
					wrong++
				}
			}
			if wrong > 0 {
				t.Errorf("goroutine %d got %d wrong answers", g, wrong)
			}
		}(g)
	}
	wg.Wait()

	l.mu.Lock()
	defer l.mu.Unlock()
	shared := l.addrs["shared"]
	if shared == nil {
		t.Fatal("the shared key was forgotten")
	}
	if n := len(shared.failures); n != Threshold+4 {
		t.Errorf("%d failure times kept for the shared key, want %d", n, Threshold+4)
	}
	if want := c.now().Add(MaxPenalty); !shared.blockedUntil.Equal(want) {
		t.Errorf("the shared key is blocked until %v, want %v", shared.blockedUntil, want)
	}
	// Every key but the shared one was seen once and the clock stood still,
	// so the table filled, gave up a tenth each time it was full, and ends
	// one address after its last pass.
	if n, want := len(l.addrs), maxAddresses-maxAddresses/10+1; n != want {
		t.Errorf("%d addresses remembered, want %d (cap %d)", n, want, maxAddresses)
	}
}
