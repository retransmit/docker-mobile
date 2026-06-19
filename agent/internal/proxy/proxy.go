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
	// NewSingleHostReverseProxy rewrites scheme+host to target; ensure the
	// outbound Host header matches so the daemon accepts it.
	origDirector := rp.Director
	rp.Director = func(r *http.Request) {
		origDirector(r)
		r.Host = target.Host
	}
	return rp, nil
}
