// Package server composes the agent's HTTP handler: an open health check
// and pairing endpoint, and behind authentication the agent's own API, the
// terminal bridge and the transparent Docker proxy.
package server

import (
	"errors"
	"io"
	"log/slog"
	"net/http"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/auth"
	"github.com/retransmit/docker-mobile/agent/internal/conns"
	"github.com/retransmit/docker-mobile/agent/internal/exec"
	"github.com/retransmit/docker-mobile/agent/internal/pairing"
	"github.com/retransmit/docker-mobile/agent/internal/proxy"
	"github.com/retransmit/docker-mobile/agent/internal/state"
	"github.com/retransmit/docker-mobile/agent/internal/throttle"
)

// APILevel is the version of the agent's own API, reported by whoami.
const APILevel = 1

// Options is everything the handler needs. Devices, Pairing and Limiter are
// required, and DockerHost must name the daemon: without them New returns an
// error. Everything else may be left out, with the effect noted at the field.
type Options struct {
	// DockerHost is where the Docker daemon listens (unix:// or tcp://).
	DockerHost string
	Devices    *state.Devices
	// LegacyToken is the shared token from the environment; empty disables it.
	LegacyToken string
	Pairing     *pairing.Manager
	// Fingerprint is the agent's certificate fingerprint (32 bytes), or empty
	// when it serves plain HTTP behind a proxy.
	Fingerprint []byte
	Limiter     *throttle.Limiter
	// Conns tracks the requests that are open so that they can be ended. Nil
	// means none is tracked: removing a device or stopping the agent then
	// ends nothing that is open.
	Conns *conns.Registry
	// Version is what whoami and a pairing report; it may be empty.
	Version string
	// RequestTimeout is how long a caller that has not been authenticated may
	// take to send the rest of its request once the headers are in. Zero
	// means 10 seconds; tests shorten it.
	RequestTimeout time.Duration
	// Log receives the access log; nil discards it.
	Log *slog.Logger
	// Now is the clock; nil means time.Now.
	Now func() time.Time
}

// New builds the agent's HTTP handler. It returns an error that names the
// first required option that is missing.
func New(o Options) (http.Handler, error) {
	// A request goes through each of these; without one it would panic.
	switch {
	case o.Devices == nil:
		return nil, errors.New("server: the option Devices is required")
	case o.Pairing == nil:
		return nil, errors.New("server: the option Pairing is required")
	case o.Limiter == nil:
		return nil, errors.New("server: the option Limiter is required")
	}
	if o.Log == nil {
		o.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if o.Now == nil {
		o.Now = time.Now
	}
	if o.RequestTimeout == 0 {
		o.RequestTimeout = defaultRequestTimeout
	}
	dockerProxy, err := proxy.New(o.DockerHost)
	if err != nil {
		return nil, err
	}
	execHandler, err := exec.NewHandler(o.DockerHost)
	if err != nil {
		return nil, err
	}
	s := &server{o: o, failures: newFailureLog(o.Log, o.Now)}
	authn := &auth.Authenticator{
		Devices:   o.Devices,
		Legacy:    o.LegacyToken,
		Limiter:   o.Limiter,
		Conns:     o.Conns,
		OnFailure: s.failures.note,
		OnCaller:  noteCaller,
	}

	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	mux.HandleFunc("POST /agent/v1/pair", s.handlePair)
	// Every request starts under a read deadline (see the last line). On the
	// three routes that need a credential it is lifted as soon as the caller
	// is known.
	mux.Handle("GET /agent/v1/whoami", authn.Require(liftReadDeadline(http.HandlerFunc(s.handleWhoami))))
	// Nothing else under /agent/ exists; it must not fall through to Docker.
	mux.HandleFunc("/agent/", func(w http.ResponseWriter, _ *http.Request) {
		auth.WriteError(w, http.StatusNotFound, "not found")
	})
	mux.Handle("GET /exec/{id}/ws", authn.Require(liftReadDeadline(fullOnly(execHandler))))
	mux.Handle("/", authn.Require(liftReadDeadline(roleGate(limitBody(dockerProxy)))))

	return readDeadline(o.RequestTimeout, accessLog(o.Log, o.Now, rejectBrowsers(mux))), nil
}

type server struct {
	o        Options
	failures *failureLog
}
