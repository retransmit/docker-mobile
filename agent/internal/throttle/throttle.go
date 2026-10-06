// Package throttle slows down guessing: it counts failed attempts per source
// address and blocks an address for a growing time once it fails too often.
package throttle

import (
	"net"
	"sync"
	"time"
)

const (
	// Window is how far back failures count.
	Window = 10 * time.Minute
	// Threshold is the number of failures in the window at which an address
	// is first blocked.
	Threshold = 10
	// BasePenalty is the first block; it doubles with every further failure.
	BasePenalty = time.Minute
	// MaxPenalty caps the block.
	MaxPenalty = 15 * time.Minute
	// maxAddresses bounds memory: beyond it, addresses with nothing left to
	// remember are dropped, and failing that the oldest ones.
	maxAddresses = 10000
)

type entry struct {
	failures     []time.Time
	blockedUntil time.Time
}

// Limiter is safe for concurrent use.
type Limiter struct {
	now func() time.Time

	mu    sync.Mutex
	addrs map[string]*entry
}

// New returns a limiter that reads time from now.
func New(now func() time.Time) *Limiter {
	return &Limiter{now: now, addrs: map[string]*entry{}}
}

// Key turns a remote address ("host:port") into the key failures are counted
// under: the host alone.
func Key(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	return host
}

// Blocked reports whether key is blocked right now, and for how much longer.
func (l *Limiter) Blocked(key string) (time.Duration, bool) {
	l.mu.Lock()
	defer l.mu.Unlock()
	e := l.addrs[key]
	if e == nil {
		return 0, false
	}
	if left := e.blockedUntil.Sub(l.now()); left > 0 {
		return left, true
	}
	return 0, false
}

// Fail records one failed attempt from key.
func (l *Limiter) Fail(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.now()
	e := l.addrs[key]
	if e == nil {
		if len(l.addrs) >= maxAddresses {
			l.evictLocked(now)
		}
		e = &entry{}
		l.addrs[key] = e
	}
	e.failures = append(recent(e.failures, now), now)
	if n := len(e.failures); n >= Threshold {
		penalty := BasePenalty
		for i := Threshold; i < n && penalty < MaxPenalty; i++ {
			penalty *= 2
		}
		if penalty > MaxPenalty {
			penalty = MaxPenalty
		}
		e.blockedUntil = now.Add(penalty)
	}
}

// recent drops failures that have left the window.
func recent(failures []time.Time, now time.Time) []time.Time {
	cut := 0
	for cut < len(failures) && now.Sub(failures[cut]) >= Window {
		cut++
	}
	return failures[cut:]
}

// evictLocked makes room: first every address with nothing left to remember,
// then, if none could go, the address whose last failure is oldest.
func (l *Limiter) evictLocked(now time.Time) {
	var oldestKey string
	var oldest time.Time
	for key, e := range l.addrs {
		e.failures = recent(e.failures, now)
		if len(e.failures) == 0 && !e.blockedUntil.After(now) {
			delete(l.addrs, key)
			continue
		}
		last := e.blockedUntil
		if n := len(e.failures); n > 0 && e.failures[n-1].After(last) {
			last = e.failures[n-1]
		}
		if oldestKey == "" || last.Before(oldest) {
			oldestKey, oldest = key, last
		}
	}
	if len(l.addrs) >= maxAddresses && oldestKey != "" {
		delete(l.addrs, oldestKey)
	}
}
