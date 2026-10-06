// Package server composes the agent's HTTP handler: an open health check
// and pairing endpoint, and behind authentication the agent's own API, the
// terminal bridge and the transparent Docker proxy.
package server

import (
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

// Options is everything the handler needs. Devices, Pairing, Limiter and
// Conns are required.
type Options struct {
	DockerHost string
	Devices    *state.Devices
	// LegacyToken is the shared token from the environment; empty disables it.
	LegacyToken string
	Pairing     *pairing.Manager
	// Fingerprint is the agent's certificate fingerprint (32 bytes), or empty
	// when it serves plain HTTP behind a proxy.
	Fingerprint []byte
	Limiter     *throttle.Limiter
	Conns       *conns.Registry
	Version     string
	// Log receives the access log; nil discards it.
	Log *slog.Logger
	// Now is the clock; nil means time.Now.
	Now func() time.Time
}

// New builds the agent's HTTP handler.
func New(o Options) (http.Handler, error) {
	if o.Log == nil {
		o.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if o.Now == nil {
		o.Now = time.Now
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
	mux.Handle("GET /agent/v1/whoami", authn.Require(http.HandlerFunc(s.handleWhoami)))
	// Nothing else under /agent/ exists; it must not fall through to Docker.
	mux.HandleFunc("/agent/", func(w http.ResponseWriter, _ *http.Request) {
		auth.WriteError(w, http.StatusNotFound, "not found")
	})
	mux.Handle("GET /exec/{id}/ws", authn.Require(fullOnly(execHandler)))
	mux.Handle("/", authn.Require(roleGate(limitBody(dockerProxy))))

	return accessLog(o.Log, o.Now, rejectBrowsers(mux)), nil
}

type server struct {
	o        Options
	failures *failureLog
}
