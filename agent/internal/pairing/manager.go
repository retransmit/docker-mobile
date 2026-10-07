package pairing

import (
	"crypto/hmac"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"sync"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/state"
)

const (
	// Lifetime is how long a pairing code stays valid.
	Lifetime = 5 * time.Minute
	// MaxTries is how many wrong proofs void a pairing.
	MaxTries = 5
)

// Outcome says how a pairing ended.
type Outcome string

const (
	Paired    Outcome = "paired"
	Expired   Outcome = "expired"
	Replaced  Outcome = "replaced"
	Voided    Outcome = "voided"
	Cancelled Outcome = "cancelled"
	Failed    Outcome = "failed"
)

// Result is delivered once to whoever started the pairing.
type Result struct {
	Outcome Outcome
	Device  state.Device // set for Paired
	Err     string       // set for Failed
}

// Pairing is a pending pairing as its starter sees it.
type Pairing struct {
	ID        string
	Code      string
	Role      state.Role
	Name      string
	ExpiresAt time.Time
}

var (
	// ErrNone means there is no pairing to redeem: none was started, or it
	// expired, was used, or was voided.
	ErrNone = errors.New("no pairing in progress")
	// ErrWrongProof means the proof did not match the pending code and the
	// fingerprint of this agent.
	ErrWrongProof = errors.New("wrong proof")
)

// Redeemed is what a phone gets for a correct proof.
type Redeemed struct {
	Device     state.Device
	Token      string
	AgentNonce []byte
	AgentProof []byte
}

// CreateDevice stores a new device and returns it with its token.
type CreateDevice func(name string, role state.Role) (state.Device, string, error)

// Manager holds at most one pending pairing, in memory only.
type Manager struct {
	now  func() time.Time
	rand io.Reader

	mu  sync.Mutex
	cur *pending
}

type pending struct {
	Pairing
	tries int
	done  chan Result
}

// NewManager returns a manager that reads time and randomness from the
// given sources. Both must be safe for use by several goroutines at once, as
// time.Now and crypto/rand.Reader are: the manager's methods may be called
// concurrently, and Start uses both outside the manager's lock.
func NewManager(now func() time.Time, rand io.Reader) *Manager {
	return &Manager{now: now, rand: rand}
}

// Start begins a pairing, replacing any pending one. The channel delivers
// exactly one Result, at the moment the pairing ends.
//
// Running out of time does not end a pairing by itself: the manager has no
// timer of its own. A pairing past ExpiresAt can no longer be redeemed, but
// it stays pending, and its channel silent, until Redeem or Expire is next
// called and ends it as expired, or until Cancel or another Start ends it.
// Whoever waits on the channel therefore arranges for Expire to be called
// at ExpiresAt.
func (m *Manager) Start(role state.Role, name string) (Pairing, <-chan Result, error) {
	if !role.Valid() {
		return Pairing{}, nil, fmt.Errorf("unknown role %q", role)
	}
	code, err := NewCode(m.rand)
	if err != nil {
		return Pairing{}, nil, err
	}
	idRaw := make([]byte, 8)
	if _, err := io.ReadFull(m.rand, idRaw); err != nil {
		return Pairing{}, nil, fmt.Errorf("random id: %w", err)
	}
	if name != "" {
		name = state.CleanName(name)
	}
	p := &pending{
		Pairing: Pairing{ID: hex.EncodeToString(idRaw), Code: code, Role: role, Name: name, ExpiresAt: m.now().Add(Lifetime)},
		done:    make(chan Result, 1),
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	m.endLocked(Result{Outcome: Replaced})
	m.cur = p
	return p.Pairing, p.done, nil
}

// Cancel ends the pairing with that id, if it is still pending.
func (m *Manager) Cancel(id string) { m.endIf(id, Result{Outcome: Cancelled}) }

// Expire ends the pairing with that id as expired, if it is still pending.
func (m *Manager) Expire(id string) { m.endIf(id, Result{Outcome: Expired}) }

func (m *Manager) endIf(id string, r Result) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cur != nil && m.cur.ID == id {
		m.endLocked(r)
	}
}

// endLocked delivers r to the pending pairing's starter and forgets it.
func (m *Manager) endLocked(r Result) {
	if m.cur == nil {
		return
	}
	m.cur.done <- r
	m.cur = nil
}

// Redeem checks a phone's proof against the pending pairing. fingerprint is
// this agent's own (empty when it has no certificate). A correct proof uses
// the pairing up: create stores the device, and the answer carries the
// agent's proof and the token.
func (m *Manager) Redeem(fingerprint, phoneNonce, proof []byte, phoneName string, create CreateDevice) (Redeemed, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.cur != nil && !m.now().Before(m.cur.ExpiresAt) {
		m.endLocked(Result{Outcome: Expired})
	}
	p := m.cur
	if p == nil {
		return Redeemed{}, ErrNone
	}
	if len(phoneNonce) != NonceLen || !hmac.Equal(proof, PhoneProof(p.Code, fingerprint, phoneNonce)) {
		p.tries++
		if p.tries >= MaxTries {
			m.endLocked(Result{Outcome: Voided})
		}
		return Redeemed{}, ErrWrongProof
	}
	agentNonce := make([]byte, NonceLen)
	if _, err := io.ReadFull(m.rand, agentNonce); err != nil {
		m.endLocked(Result{Outcome: Failed, Err: err.Error()})
		return Redeemed{}, fmt.Errorf("random nonce: %w", err)
	}
	name := p.Name
	if name == "" {
		name = phoneName
	}
	dev, token, err := create(name, p.Role)
	if err != nil {
		m.endLocked(Result{Outcome: Failed, Err: err.Error()})
		return Redeemed{}, fmt.Errorf("store device: %w", err)
	}
	out := Redeemed{Device: dev, Token: token, AgentNonce: agentNonce, AgentProof: AgentProof(p.Code, fingerprint, phoneNonce, agentNonce)}
	m.endLocked(Result{Outcome: Paired, Device: dev})
	return out, nil
}
