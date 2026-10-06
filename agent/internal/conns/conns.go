// Package conns tracks the requests each device has open, so that removing a
// device, or stopping the agent, can end them.
package conns

import (
	"context"
	"sync"
)

// Registry is safe for concurrent use.
type Registry struct {
	mu     sync.Mutex
	next   uint64
	open   map[string]map[uint64]context.CancelFunc
	closed bool
}

// New returns an empty registry.
func New() *Registry {
	return &Registry{open: map[string]map[uint64]context.CancelFunc{}}
}

// Track returns a context for one request of deviceID. The context ends when
// parent ends, when the device is closed, or when everything is closed. The
// caller must call release when the request is over.
func (r *Registry) Track(parent context.Context, deviceID string) (ctx context.Context, release func()) {
	ctx, cancel := context.WithCancel(parent)
	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		cancel()
		return ctx, func() {}
	}
	r.next++
	n := r.next
	if r.open[deviceID] == nil {
		r.open[deviceID] = map[uint64]context.CancelFunc{}
	}
	r.open[deviceID][n] = cancel
	r.mu.Unlock()
	return ctx, func() {
		r.mu.Lock()
		if set := r.open[deviceID]; set != nil {
			delete(set, n)
			if len(set) == 0 {
				delete(r.open, deviceID)
			}
		}
		r.mu.Unlock()
		cancel()
	}
}

// CloseDevice ends every open request of one device and reports how many.
func (r *Registry) CloseDevice(deviceID string) int {
	r.mu.Lock()
	set := r.open[deviceID]
	delete(r.open, deviceID)
	r.mu.Unlock()
	for _, cancel := range set {
		cancel()
	}
	return len(set)
}

// CloseAll ends every open request and refuses new ones from then on.
func (r *Registry) CloseAll() {
	r.mu.Lock()
	all := r.open
	r.open = map[string]map[uint64]context.CancelFunc{}
	r.closed = true
	r.mu.Unlock()
	for _, set := range all {
		for _, cancel := range set {
			cancel()
		}
	}
}

// Open reports how many requests a device has open.
func (r *Registry) Open(deviceID string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	return len(r.open[deviceID])
}
