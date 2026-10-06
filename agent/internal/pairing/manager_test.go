package pairing

import (
	"bytes"
	"crypto/rand"
	"errors"
	"testing"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/state"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time          { return c.t }
func (c *clock) advance(d time.Duration) { c.t = c.t.Add(d) }

func newClock() *clock { return &clock{t: time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)} }

var (
	agentFP = bytes.Repeat([]byte{7}, 32)
	nonce   = bytes.Repeat([]byte{4}, NonceLen)
)

// creator records what Redeem asked to store.
type creator struct {
	calls []string
	err   error
}

func (c *creator) create(name string, role state.Role) (state.Device, string, error) {
	c.calls = append(c.calls, name+"/"+string(role))
	if c.err != nil {
		return state.Device{}, "", c.err
	}
	return state.Device{ID: "abcd1234", Name: name, Role: role}, "dm1.abcd1234.secret", nil
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
	m := NewManager(newClock().now, rand.Reader)
	p, _, _ := m.Start(state.RoleFull, "")
	short := []byte{1, 2, 3}
	if _, err := m.Redeem(agentFP, short, PhoneProof(p.Code, agentFP, short), "x", (&creator{}).create); !errors.Is(err, ErrWrongProof) {
		t.Fatalf("err = %v, want ErrWrongProof", err)
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
	if _, err := m.Redeem(agentFP, nonce, PhoneProof(p.Code, agentFP, nonce), "x", c.create); err == nil {
		t.Fatal("a failed store was reported as success")
	}
	if r := result(t, done); r.Outcome != Failed || r.Err != "disk full" {
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
