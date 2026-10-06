package throttle

import (
	"fmt"
	"testing"
	"time"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time          { return c.t }
func (c *clock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newClock() *clock { return &clock{t: time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)} }

func fail(l *Limiter, key string, n int) {
	for i := 0; i < n; i++ {
		l.Fail(key)
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

func TestKeyDropsThePort(t *testing.T) {
	cases := map[string]string{
		"192.168.1.5:51234": "192.168.1.5",
		"[::1]:8443":        "::1",
		"[fe80::1%eth0]:1":  "fe80::1%eth0",
		"no-port":           "no-port",
		"":                  "",
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
	// Everything so far is still inside the window: the oldest one goes.
	l.Fail("one-more")
	if n := len(l.addrs); n > maxAddresses {
		t.Fatalf("%d addresses remembered, cap is %d", n, maxAddresses)
	}
	if _, ok := l.addrs["addr-0"]; ok {
		t.Fatal("the oldest address was not dropped")
	}
	// Once the window has passed, everything forgettable goes at once.
	c.advance(Window)
	l.Fail("after-the-window")
	if n := len(l.addrs); n != 1 {
		t.Fatalf("%d addresses remembered after the window, want 1", n)
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
