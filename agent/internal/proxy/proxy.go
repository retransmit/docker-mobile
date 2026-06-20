// Package proxy forwards Docker Engine API requests to the daemon socket and
// streams responses back unchanged.
package proxy

import (
	"net/http"
	"net/http/httputil"
	"net/url"

	"github.com/0xLennox07/docker-mobile/agent/internal/dockerhost"
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
	}
	return rp, nil
}
