package pairing

import (
	"bytes"
	"crypto/rand"
	"errors"
	"fmt"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/state"
)

// clock is a time source the tests set by hand. Goroutines may share it.
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

var (
	agentFP = bytes.Repeat([]byte{7}, 32)
	nonce   = bytes.Repeat([]byte{4}, NonceLen)
	// wrongProof has the length of a proof and proves nothing.
	wrongProof = bytes.Repeat([]byte{0}, 32)
)

// creator records what Redeem asked to store. With err set it fails, and
// still returns a device and a token; neither may get past Redeem.
type creator struct {
	calls []string
	err   error
}

func (c *creator) create(name string, role state.Role) (state.Device, string, error) {
	c.calls = append(c.calls, name+"/"+string(role))
	return state.Device{ID: "abcd1234", Name: name, Role: role}, "dm1.abcd1234.secret", c.err
}

// sharedCreator is a creator that many goroutines may call at once. It
// counts its calls, and every call returns a device and a token of its own.
type sharedCreator struct{ calls atomic.Int32 }

func (c *sharedCreator) create(name string, role state.Role) (state.Device, string, error) {
	n := c.calls.Add(1)
	// Give the other goroutines a turn while this call is in flight: a
	// manager that held them back only up to here would now let them in.
	for i := 0; i < 8; i++ {
		runtime.Gosched()
	}
	id := fmt.Sprintf("%08x", n)
	return state.Device{ID: id, Name: name, Role: role}, "dm1." + id + ".secret", nil
}

var errNoRandomness = errors.New("no randomness")

// budgetRand is a random source that fails once it has handed out its budget
// of bytes. A negative budget never runs out.
type budgetRand struct{ left int }

func (r *budgetRand) Read(p []byte) (int, error) {
	if r.left >= 0 {
		if len(p) > r.left {
			return 0, errNoRandomness
		}
		r.left -= len(p)
	}
	return rand.Read(p)
}

// handedOutNothing reports whether a redeem returned the zero value: no
// device, no token, no nonce and no proof.
func handedOutNothing(r Redeemed) bool {
	return r.Device == (state.Device{}) && r.Token == "" && r.AgentNonce == nil && r.AgentProof == nil
}

// collect reads what a pairing's channel delivers until stop is closed, then
// hands all of it over on out. It reads while the manager is at work, so a
// second result for one pairing is counted instead of blocking the manager.
func collect(ch <-chan Result, stop <-chan struct{}, out chan<- []Result) {
	var got []Result
	for {
		select {
		case r := <-ch:
			got = append(got, r)
		case <-stop:
			for {
				select {
				case r := <-ch:
					got = append(got, r)
				default:
					out <- got
					return
				}
			}
		}
	}
}

func result(t *testing.T, ch <-chan Result) Result {
	t.Helper()
	select {
	case r := <-ch:
		return r
	default:
		t.Fatal("no result was delivered")
		return Result{}
	}
}

func pendingStill(t *testing.T, ch <-chan Result) {
	t.Helper()
	select {
	case r := <-ch:
		t.Fatalf("the pairing ended early: %+v", r)
	default:
	}
}

func TestACorrectProofPairsOnce(t *testing.T) {
	m := NewManager(newClock().now, rand.Reader)
	p, done, err := m.Start(state.RoleReadOnly, "")
	if err != nil {
		t.Fatal(err)
	}
	if len(p.Code) != CodeLen || p.Role != state.RoleReadOnly || p.ID == "" {
		t.Fatalf("pairing = %+v", p)
	}
	c := &creator{}
	got, err := m.Redeem(agentFP, nonce, PhoneProof(p.Code, agentFP, nonce), "Pixel 8", c.create)
	if err != nil {
		t.Fatalf("Redeem: %v", err)
	}
	if got.Token != "dm1.abcd1234.secret" || got.Device.Name != "Pixel 8" || got.Device.Role != state.RoleReadOnly {
		t.Fatalf("redeemed = %+v", got)
	}
	if len(got.AgentNonce) != NonceLen || !bytes.Equal(got.AgentProof, AgentProof(p.Code, agentFP, nonce, got.AgentNonce)) {
		t.Fatal("the agent proof does not verify")
	}
	if r := result(t, done); r.Outcome != Paired || r.Device.ID != "abcd1234" {
		t.Fatalf("result = %+v", r)
	}
	// Single use: the same proof again finds nothing.
	if _, err := m.Redeem(agentFP, nonce, PhoneProof(p.Code, agentFP, nonce), "again", c.create); !errors.Is(err, ErrNone) {
		t.Fatalf("second redeem err = %v, want ErrNone", err)
	}
	if len(c.calls) != 1 {
		t.Fatalf("create calls = %v", c.calls)
	}
}

func TestTheNameGivenAtStartWins(t *testing.T) {
	m := NewManager(newClock().now, rand.Reader)
	p, _, _ := m.Start(state.RoleFull, "  kitchen tablet ")
	if p.Name != "kitchen tablet" {
		t.Fatalf("name = %q", p.Name)
	}
	c := &creator{}
	if _, err := m.Redeem(agentFP, nonce, PhoneProof(p.Code, agentFP, nonce), "Pixel 8", c.create); err != nil {
		t.Fatal(err)
	}
	if c.calls[0] != "kitchen tablet/full" {
		t.Fatalf("create got %v", c.calls)
	}
}

func TestSomeoneInTheMiddleCannotPair(t *testing.T) {
	m := NewManager(newClock().now, rand.Reader)
	p, done, _ := m.Start(state.RoleFull, "")
	c := &creator{}
	// The phone saw the attacker's certificate, so its proof is bound to that.
	attackerFP := bytes.Repeat([]byte{8}, 32)
	relayed := PhoneProof(p.Code, attackerFP, nonce)
	if _, err := m.Redeem(agentFP, nonce, relayed, "Pixel 8", c.create); !errors.Is(err, ErrWrongProof) {
		t.Fatalf("err = %v, want ErrWrongProof", err)
	}
	if len(c.calls) != 0 {
		t.Fatal("a device was created for a relayed proof")
	}
	pendingStill(t, done)
	// Directly, over the certificate the agent really has, the code still
	// works.
	got, err := m.Redeem(agentFP, nonce, PhoneProof(p.Code, agentFP, nonce), "Pixel 8", c.create)
	if err != nil || got.Token == "" {
		t.Fatalf("the code after the relayed proof: redeemed = %+v, err = %v", got, err)
	}
	if r := result(t, done); r.Outcome != Paired {
		t.Fatalf("result = %+v", r)
	}
}

func TestFiveWrongProofsVoidThePairing(t *testing.T) {
	m := NewManager(newClock().now, rand.Reader)
	p, done, _ := m.Start(state.RoleFull, "")
	c := &creator{}
	wrong := bytes.Repeat([]byte{0}, 32)
	for i := 1; i <= MaxTries; i++ {
		if i == MaxTries {
			pendingStill(t, done)
		}
		if _, err := m.Redeem(agentFP, nonce, wrong, "x", c.create); !errors.Is(err, ErrWrongProof) {
			t.Fatalf("try %d: err = %v", i, err)
		}
	}
	if r := result(t, done); r.Outcome != Voided {
		t.Fatalf("result = %+v", r)
	}
	if _, err := m.Redeem(agentFP, nonce, PhoneProof(p.Code, agentFP, nonce), "x", c.create); !errors.Is(err, ErrNone) {
		t.Fatalf("the right proof after voiding: err = %v, want ErrNone", err)
	}
}

func TestAWrongNonceLengthIsAWrongProof(t *testing.T) {
	for _, n := range []int{0, 31, 33, 64} {
		m := NewManager(newClock().now, rand.Reader)
		p, _, _ := m.Start(state.RoleFull, "")
		c := &creator{}
		odd := bytes.Repeat([]byte{4}, n)
		// The proof is the right one for that nonce, so the length of the
		// nonce is all there is to refuse.
		if _, err := m.Redeem(agentFP, odd, PhoneProof(p.Code, agentFP, odd), "x", c.create); !errors.Is(err, ErrWrongProof) {
			t.Fatalf("a nonce of %d bytes: err = %v, want ErrWrongProof", n, err)
		}
		if len(c.calls) != 0 {
			t.Fatalf("a nonce of %d bytes: a device was created", n)
		}
	}
}

func TestACodeExpiresAfterFiveMinutes(t *testing.T) {
	c := newClock()
	m := NewManager(c.now, rand.Reader)
	p, done, _ := m.Start(state.RoleFull, "")
	if !p.ExpiresAt.Equal(c.now().Add(Lifetime)) {
		t.Fatalf("expiry = %v", p.ExpiresAt)
	}
	c.advance(Lifetime - time.Second)
	// One second before the end the code is still alive: a wrong proof is
	// answered as wrong, not as if there were nothing to redeem.
	if _, err := m.Redeem(agentFP, nonce, wrongProof, "x", (&creator{}).create); !errors.Is(err, ErrWrongProof) {
		t.Fatalf("one second before the end: err = %v, want ErrWrongProof", err)
	}
	pendingStill(t, done)
	c.advance(time.Second)
	if _, err := m.Redeem(agentFP, nonce, PhoneProof(p.Code, agentFP, nonce), "x", (&creator{}).create); !errors.Is(err, ErrNone) {
		t.Fatalf("err = %v, want ErrNone", err)
	}
	if r := result(t, done); r.Outcome != Expired {
		t.Fatalf("result = %+v", r)
	}
}

func TestANewPairingReplacesThePendingOne(t *testing.T) {
	m := NewManager(newClock().now, rand.Reader)
	first, firstDone, _ := m.Start(state.RoleFull, "")
	second, secondDone, _ := m.Start(state.RoleFull, "")
	if r := result(t, firstDone); r.Outcome != Replaced {
		t.Fatalf("first result = %+v", r)
	}
	c := &creator{}
	if _, err := m.Redeem(agentFP, nonce, PhoneProof(first.Code, agentFP, nonce), "x", c.create); !errors.Is(err, ErrWrongProof) {
		t.Fatalf("the replaced code: err = %v, want ErrWrongProof", err)
	}
	if _, err := m.Redeem(agentFP, nonce, PhoneProof(second.Code, agentFP, nonce), "x", c.create); err != nil {
		t.Fatalf("the new code: %v", err)
	}
	if r := result(t, secondDone); r.Outcome != Paired {
		t.Fatalf("second result = %+v", r)
	}
}

func TestCancelAndExpireOnlyTouchTheirOwnPairing(t *testing.T) {
	m := NewManager(newClock().now, rand.Reader)
	old, _, _ := m.Start(state.RoleFull, "")
	cur, done, _ := m.Start(state.RoleFull, "")
	m.Cancel(old.ID)
	m.Expire(old.ID)
	pendingStill(t, done)
	m.Cancel(cur.ID)
	if r := result(t, done); r.Outcome != Cancelled {
		t.Fatalf("result = %+v", r)
	}
	m.Cancel(cur.ID) // already gone: nothing happens

	p, done2, _ := m.Start(state.RoleFull, "")
	m.Expire(p.ID)
	if r := result(t, done2); r.Outcome != Expired {
		t.Fatalf("result = %+v", r)
	}
}

func TestAFailedStoreEndsThePairingAsFailed(t *testing.T) {
	m := NewManager(newClock().now, rand.Reader)
	p, done, _ := m.Start(state.RoleFull, "")
	c := &creator{err: errors.New("disk full")}
	right := PhoneProof(p.Code, agentFP, nonce)
	got, err := m.Redeem(agentFP, nonce, right, "x", c.create)
	if err == nil {
		t.Fatal("a failed store was reported as success")
	}
	if !handedOutNothing(got) {
		t.Fatalf("a failed store handed out %+v", got)
	}
	if r := result(t, done); r.Outcome != Failed || r.Err != "disk full" {
		t.Fatalf("result = %+v", r)
	}
	if _, err := m.Redeem(agentFP, nonce, right, "x", c.create); !errors.Is(err, ErrNone) {
		t.Fatalf("second redeem err = %v, want ErrNone", err)
	}
}

func TestAFailedRandomSourceInStartLeavesThePendingPairingAlone(t *testing.T) {
	// Start draws the code first and the id after it.
	for _, tc := range []struct {
		what   string
		budget int
	}{
		{"the code", 0},
		{"the id", CodeLen},
	} {
		src := &budgetRand{left: -1}
		m := NewManager(newClock().now, src)
		p, done, err := m.Start(state.RoleFull, "")
		if err != nil {
			t.Fatal(err)
		}
		src.left = tc.budget
		if _, _, err := m.Start(state.RoleFull, ""); !errors.Is(err, errNoRandomness) {
			t.Fatalf("no randomness for %s: err = %v", tc.what, err)
		}
		pendingStill(t, done)
		// The pairing that was pending is still the one that redeems.
		src.left = -1
		c := &creator{}
		if _, err := m.Redeem(agentFP, nonce, PhoneProof(p.Code, agentFP, nonce), "x", c.create); err != nil {
			t.Fatalf("no randomness for %s: the pending pairing: %v", tc.what, err)
		}
		if r := result(t, done); r.Outcome != Paired {
			t.Fatalf("no randomness for %s: result = %+v", tc.what, r)
		}
	}
}

func TestAFailedRandomSourceInRedeemEndsThePairingAsFailed(t *testing.T) {
	src := &budgetRand{left: -1}
	m := NewManager(newClock().now, src)
	p, done, err := m.Start(state.RoleFull, "")
	if err != nil {
		t.Fatal(err)
	}
	src.left = 0
	c := &creator{}
	got, err := m.Redeem(agentFP, nonce, PhoneProof(p.Code, agentFP, nonce), "x", c.create)
	if !errors.Is(err, errNoRandomness) {
		t.Fatalf("err = %v, want the failure of the random source", err)
	}
	if !handedOutNothing(got) {
		t.Fatalf("a redeem without randomness handed out %+v", got)
	}
	if len(c.calls) != 0 {
		t.Fatalf("create was called: %v", c.calls)
	}
	if r := result(t, done); r.Outcome != Failed || r.Err != errNoRandomness.Error() {
		t.Fatalf("result = %+v", r)
	}
}

func TestPairingWithoutACertificateUsesAnEmptyFingerprint(t *testing.T) {
	m := NewManager(newClock().now, rand.Reader)
	p, _, _ := m.Start(state.RoleFull, "")
	c := &creator{}
	if _, err := m.Redeem(nil, nonce, PhoneProof(p.Code, agentFP, nonce), "x", c.create); !errors.Is(err, ErrWrongProof) {
		t.Fatalf("a proof bound to a fingerprint was accepted without one: %v", err)
	}
	if _, err := m.Redeem(nil, nonce, PhoneProof(p.Code, nil, nonce), "x", c.create); err != nil {
		t.Fatalf("Redeem: %v", err)
	}
}

func TestStartRejectsAnUnknownRole(t *testing.T) {
	m := NewManager(newClock().now, rand.Reader)
	if _, _, err := m.Start(state.Role("admin"), ""); err == nil {
		t.Fatal("unknown role accepted")
	}
}

func TestConcurrentRedeemsYieldOneDevice(t *testing.T) {
	const callers = 16
	m := NewManager(newClock().now, rand.Reader)
	p, done, err := m.Start(state.RoleFull, "")
	if err != nil {
		t.Fatal(err)
	}
	right := PhoneProof(p.Code, agentFP, nonce)
	c := &sharedCreator{}

	stop := make(chan struct{})
	delivered := make(chan []Result, 1)
	go collect(done, stop, delivered)

	type answer struct {
		got Redeemed
		err error
	}
	answers := make(chan answer, callers)
	release := make(chan struct{})
	var wg sync.WaitGroup
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-release
			got, err := m.Redeem(agentFP, nonce, right, "Pixel 8", c.create)
			answers <- answer{got, err}
		}()
	}
	close(release)
	wg.Wait()
	close(answers)
	close(stop)
	results := <-delivered

	var winner Redeemed
	paired, none := 0, 0
	for a := range answers {
		switch {
		case a.err == nil:
			paired++
			winner = a.got
		case errors.Is(a.err, ErrNone):
			none++
			if !handedOutNothing(a.got) {
				t.Errorf("a redeem that found nothing handed out %+v", a.got)
			}
		default:
			t.Errorf("Redeem: %v", a.err)
		}
	}
	if paired != 1 || none != callers-1 {
		t.Fatalf("%d redeems succeeded and %d found nothing, want 1 and %d", paired, none, callers-1)
	}
	if winner.Token == "" {
		t.Fatalf("the redeem that succeeded has no token: %+v", winner)
	}
	if n := c.calls.Load(); n != 1 {
		t.Fatalf("create ran %d times, want once", n)
	}
	if len(results) != 1 || results[0].Outcome != Paired || results[0].Device.ID != winner.Device.ID {
		t.Fatalf("results = %+v, want one that says paired with device %s", results, winner.Device.ID)
	}
}

func TestConcurrentWrongProofsCancelAndStartEndEachPairingOnce(t *testing.T) {
	// Enough wrong proofs to void a pairing, should they all reach the same.
	const wrongTries = MaxTries
	for round := 0; round < 4; round++ {
		m := NewManager(newClock().now, rand.Reader)
		first, firstDone, err := m.Start(state.RoleFull, "")
		if err != nil {
			t.Fatal(err)
		}
		right := PhoneProof(first.Code, agentFP, nonce)
		c := &sharedCreator{}

		stop := make(chan struct{})
		firstDelivered := make(chan []Result, 1)
		secondDelivered := make(chan []Result, 1)
		go collect(firstDone, stop, firstDelivered)

		release := make(chan struct{})
		var wg sync.WaitGroup
		var accepted atomic.Int32
		run := func(call func()) {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-release
				call()
			}()
		}
		wrong := func() {
			got, err := m.Redeem(agentFP, nonce, wrongProof, "x", c.create)
			if !errors.Is(err, ErrWrongProof) && !errors.Is(err, ErrNone) {
				t.Errorf("round %d: a wrong proof: err = %v", round, err)
			}
			if !handedOutNothing(got) {
				t.Errorf("round %d: a wrong proof was handed %+v", round, got)
			}
		}
		cancel := func() { m.Cancel(first.ID) }
		start := func() {
			_, ch, err := m.Start(state.RoleFull, "")
			if err != nil {
				t.Errorf("round %d: the second Start: %v", round, err)
				secondDelivered <- nil
				return
			}
			go collect(ch, stop, secondDelivered)
		}
		redeem := func() {
			// Right for the first pairing, and wrong for the second if that
			// one is pending by now.
			got, err := m.Redeem(agentFP, nonce, right, "Pixel 8", c.create)
			switch {
			case err == nil:
				accepted.Add(1)
				if got.Token == "" {
					t.Errorf("round %d: the right proof was accepted without a token: %+v", round, got)
				}
			case errors.Is(err, ErrNone), errors.Is(err, ErrWrongProof):
				if !handedOutNothing(got) {
					t.Errorf("round %d: a refused redeem handed out %+v", round, got)
				}
			default:
				t.Errorf("round %d: the right proof: err = %v", round, err)
			}
		}
		ops := []func(){cancel, start, redeem}
		for i := 0; i < wrongTries; i++ {
			ops = append(ops, wrong)
		}
		// Every round launches the calls in another order, so that it is not
		// always the same one that reaches the manager first.
		for i := range ops {
			run(ops[(i+round*3)%len(ops)])
		}
		close(release)
		wg.Wait()
		close(stop)
		firstResults, secondResults := <-firstDelivered, <-secondDelivered

		// The first pairing has ended for sure, the second Start saw to that.
		if len(firstResults) != 1 {
			t.Fatalf("round %d: the first pairing delivered %d results: %+v", round, len(firstResults), firstResults)
		}
		if len(secondResults) > 1 {
			t.Fatalf("round %d: the second pairing delivered %d results: %+v", round, len(secondResults), secondResults)
		}
		calls := int(c.calls.Load())
		if calls > 1 {
			t.Fatalf("round %d: create ran %d times", round, calls)
		}
		// Only the first code was ever proved, so only the first pairing can
		// end as paired, and it does exactly when a device was created.
		paired := 0
		if firstResults[0].Outcome == Paired {
			paired = 1
		}
		if paired != calls || int(accepted.Load()) != calls {
			t.Fatalf("round %d: create ran %d times, the right proof was accepted %d times, the first pairing ended as %s",
				round, calls, accepted.Load(), firstResults[0].Outcome)
		}
		for _, r := range secondResults {
			if r.Outcome == Paired {
				t.Fatalf("round %d: the second pairing ended as paired: %+v", round, r)
			}
		}
	}
}
