// Package throttle slows down guessing: it counts failed attempts per source
// address (per /64 network for IPv6) and blocks a source for a growing time
// once it fails too often.
package throttle

import (
	"net"
	"net/netip"
	"slices"
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
	// maxFailures is how many failure times one address keeps, the newest
	// ones. The penalty reaches MaxPenalty at this count and stays there, so
	// older times change nothing.
	maxFailures = Threshold + 4
	// maxAddresses bounds memory: a full table makes room before it takes a
	// new address, see evictLocked.
	maxAddresses = 10000
	// evictBatch is how many addresses a full table gives up in one pass when
	// none of them can simply be forgotten.
	evictBatch = maxAddresses / 10
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

// New returns a limiter that reads time from now. Outside tests, pass
// time.Now itself: its values carry the monotonic reading, so a step of the
// wall clock moves no block end. A clock without that reading lets such a
// step shorten or lengthen every block.
func New(now func() time.Time) *Limiter {
	return &Limiter{now: now, addrs: map[string]*entry{}}
}

// Key turns a remote address ("host:port") into the key failures are counted
// under. An IPv4 address is its own key, also when it is written as IPv6
// ("::ffff:192.0.2.7"). An IPv6 address is counted under its /64 network
// ("2001:db8:1:2::/64"), because whoever has one address in such a network
// can usually take any other in it. A zone stays in the key
// ("fe80::/64%eth0"): a link-local network on another interface is another
// network. A host that is not an IP address is returned as it is, and so is
// a string that is not "host:port".
func Key(remoteAddr string) string {
	host, _, err := net.SplitHostPort(remoteAddr)
	if err != nil {
		return remoteAddr
	}
	addr, err := netip.ParseAddr(host)
	if err != nil {
		return host
	}
	zone := addr.Zone()
	addr = addr.WithZone("").Unmap()
	if addr.Is4() {
		return addr.String()
	}
	network := netip.PrefixFrom(addr, 64).Masked().String()
	if zone != "" {
		network += "%" + zone
	}
	return network
}

// Blocked reports whether key is blocked right now, and for how much longer.
// Ask it before a credential is checked: for a blocked address the caller
// neither runs the check nor calls Fail.
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

// Fail records one failed attempt from key. Call it once for every check
// that tested a guess and found it wrong, and never after a success. It is
// not meant for an address that Blocked reports as blocked; when it is called
// for one all the same, the failure counts and the block can only get longer.
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
	if over := len(e.failures) - maxFailures; over > 0 {
		e.failures = e.failures[over:]
	}
	if n := len(e.failures); n >= Threshold {
		penalty := BasePenalty
		for i := Threshold; i < n && penalty < MaxPenalty; i++ {
			penalty *= 2
		}
		if penalty > MaxPenalty {
			penalty = MaxPenalty
		}
		// The end of a block only moves forward. A block can outlast the
		// window, and failures counted after the older ones have left it are
		// worth a smaller penalty; that must not cut a running block short.
		if until := now.Add(penalty); until.After(e.blockedUntil) {
			e.blockedUntil = until
		}
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

// evictLocked makes room in a full table. First every address with nothing
// left to remember goes: no failure inside the window and no running block.
// If the table is still full after that, evictBatch addresses go in one pass,
// so that the next new addresses need no pass at all. Addresses that are not
// blocked go before blocked ones; among those not blocked the one whose last
// failure is oldest goes first, among blocked ones the one whose block ends
// soonest.
func (l *Limiter) evictLocked(now time.Time) {
	for key, e := range l.addrs {
		e.failures = recent(e.failures, now)
		if len(e.failures) == 0 && !e.blockedUntil.After(now) {
			delete(l.addrs, key)
		}
	}
	if len(l.addrs) < maxAddresses {
		return
	}
	type candidate struct {
		key     string
		blocked bool
		// at is the end of the block of a blocked address, and the last
		// failure of one that is not blocked.
		at time.Time
	}
	candidates := make([]candidate, 0, len(l.addrs))
	for key, e := range l.addrs {
		c := candidate{key: key, blocked: e.blockedUntil.After(now), at: e.blockedUntil}
		if !c.blocked {
			c.at = e.failures[len(e.failures)-1]
		}
		candidates = append(candidates, c)
	}
	slices.SortFunc(candidates, func(a, b candidate) int {
		if a.blocked != b.blocked {
			if a.blocked {
				return 1
			}
			return -1
		}
		return a.at.Compare(b.at)
	})
	for _, c := range candidates[:evictBatch] {
		delete(l.addrs, c.key)
	}
}
