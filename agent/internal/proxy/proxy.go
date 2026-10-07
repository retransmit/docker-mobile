// Package proxy forwards Docker Engine API requests to the daemon socket and
// streams responses back unchanged.
package proxy

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"

	"github.com/retransmit/docker-mobile/agent/internal/dockerhost"
)

func New(dockerHost string) (http.Handler, error) {
	dial, base, err := dockerhost.DialContextFor(dockerHost)
	if err != nil {
		return nil, err
	}
	target, err := url.Parse(base)
	if err != nil {
		return nil, err
	}
	rp := httputil.NewSingleHostReverseProxy(target)
	rp.Transport = &http.Transport{DialContext: dial}
	// Flush each chunk to the client immediately so live streams (logs/stats/
	// events) are real-time. ReverseProxy already does this for unknown-length
	// responses; setting it explicitly guarantees it regardless of headers.
	rp.FlushInterval = -1
	// NewSingleHostReverseProxy rewrites scheme+host to target; ensure the
	// outbound Host header matches so the daemon accepts it.
	origDirector := rp.Director
	rp.Director = func(r *http.Request) {
		origDirector(r)
		r.Host = target.Host
		// The bearer token is for the agent. The daemon has no use for it and
		// must not see it (registry credentials travel in X-Registry-Auth).
		r.Header.Del("Authorization")
	}
	// Transport errors become JSON answers the app can show, not a bare 502,
	// and stay out of the process log (the access log has the status).
	rp.ErrorLog = log.New(io.Discard, "", 0)
	rp.ErrorHandler = func(w http.ResponseWriter, _ *http.Request, err error) {
		status, message := http.StatusBadGateway, "The agent cannot reach the Docker daemon"
		var tooLarge *http.MaxBytesError
		if errors.As(err, &tooLarge) {
			status, message = http.StatusRequestEntityTooLarge, "The request body is too large"
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(status)
		json.NewEncoder(w).Encode(map[string]string{"message": message})
	}
	return rp, nil
}
