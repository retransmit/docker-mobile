package server

import (
	"bufio"
	"context"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"regexp"
	"sync"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/auth"
	"github.com/retransmit/docker-mobile/agent/internal/policy"
	"github.com/retransmit/docker-mobile/agent/internal/state"
	"github.com/retransmit/docker-mobile/agent/internal/throttle"
)

// ReadOnlyMessage is what a read-only device gets for a refused request. The
// app shows it as is.
const ReadOnlyMessage = "This device has read-only access"

// maxBody caps request bodies, except on the few routes that upload.
const maxBody = 16 << 20

// uploads are the routes whose bodies may be large: image builds, image
// loads and file uploads into a container.
var uploads = regexp.MustCompile(`^(/v[0-9]+\.[0-9]+)?(/build|/images/load|/containers/[^/]+/archive)$`)

// rejectBrowsers refuses anything a web page sent. The app never sends an
// Origin header; a browser always does on a cross-site request.
func rejectBrowsers(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Origin") != "" {
			auth.WriteError(w, http.StatusForbidden, "requests from web pages are not accepted")
			return
		}
		next.ServeHTTP(w, r)
	})
}

// roleGate lets a read-only device through only for the reads on the list.
func roleGate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		dev, _ := auth.Caller(r.Context())
		if dev.Role != state.RoleFull && !policy.AllowedReadOnly(r.Method, r.URL.EscapedPath()) {
			auth.WriteError(w, http.StatusForbidden, ReadOnlyMessage)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// fullOnly refuses read-only devices outright.
func fullOnly(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if dev, _ := auth.Caller(r.Context()); dev.Role != state.RoleFull {
			auth.WriteError(w, http.StatusForbidden, ReadOnlyMessage)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// limitBody caps the request body unless the route is an upload.
func limitBody(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Body != nil && !uploads.MatchString(r.URL.Path) {
			r.Body = http.MaxBytesReader(w, r.Body, maxBody)
		}
		next.ServeHTTP(w, r)
	})
}

// requestInfo travels with a request so that the access log, which wraps
// everything, can name the device that authentication found further in.
type requestInfo struct {
	mu     sync.Mutex
	device state.Device
}

type infoKey struct{}

func noteCaller(r *http.Request, dev state.Device) {
	if info, ok := r.Context().Value(infoKey{}).(*requestInfo); ok {
		info.mu.Lock()
		info.device = dev
		info.mu.Unlock()
	}
}

// accessLog writes one line per finished request. It never logs a query
// string, a header or a body. The health check is not logged.
func accessLog(log *slog.Logger, now func() time.Time, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/healthz" {
			next.ServeHTTP(w, r)
			return
		}
		start := now()
		info := &requestInfo{}
		sw := &statusWriter{ResponseWriter: w}
		next.ServeHTTP(sw, r.WithContext(context.WithValue(r.Context(), infoKey{}, info)))
		info.mu.Lock()
		dev := info.device
		info.mu.Unlock()
		log.Info("request",
			"device", dev.ID,
			"name", dev.Name,
			"method", r.Method,
			"path", r.URL.Path,
			"status", sw.code(),
			"bytes", sw.bytes,
			"ms", now().Sub(start).Milliseconds(),
		)
	})
}

// statusWriter records the status and size of a response. It keeps
// streaming (Flush) and connection takeover (Hijack) working, which the
// proxy and the terminal bridge depend on.
type statusWriter struct {
	http.ResponseWriter
	status   int
	bytes    int64
	hijacked bool
}

func (w *statusWriter) WriteHeader(status int) {
	if w.status == 0 {
		w.status = status
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *statusWriter) Write(p []byte) (int, error) {
	if w.status == 0 {
		w.status = http.StatusOK
	}
	n, err := w.ResponseWriter.Write(p)
	w.bytes += int64(n)
	return n, err
}

func (w *statusWriter) Flush() {
	if f, ok := w.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (w *statusWriter) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := w.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, errors.New("the connection cannot be taken over")
	}
	conn, rw, err := h.Hijack()
	if err == nil {
		w.hijacked = true
	}
	return conn, rw, err
}

// Unwrap lets http.ResponseController reach the real writer.
func (w *statusWriter) Unwrap() http.ResponseWriter { return w.ResponseWriter }

func (w *statusWriter) code() int {
	switch {
	case w.hijacked:
		return http.StatusSwitchingProtocols
	case w.status == 0:
		return http.StatusOK
	}
	return w.status
}

// failureLog reports failed authentications, at most one line a second per
// source address.
type failureLog struct {
	log *slog.Logger
	now func() time.Time

	mu   sync.Mutex
	last map[string]time.Time
}

// maxFailureAddrs bounds what failureLog remembers.
const maxFailureAddrs = 1000

func newFailureLog(log *slog.Logger, now func() time.Time) *failureLog {
	return &failureLog{log: log, now: now, last: map[string]time.Time{}}
}

func (f *failureLog) note(remoteAddr string) {
	key := throttle.Key(remoteAddr)
	now := f.now()
	f.mu.Lock()
	if last, seen := f.last[key]; seen && now.Sub(last) < time.Second {
		f.mu.Unlock()
		return
	}
	if len(f.last) >= maxFailureAddrs {
		f.last = map[string]time.Time{}
	}
	f.last[key] = now
	f.mu.Unlock()
	f.log.Warn("authentication failed", "from", key)
}
