// Package dockerhost converts a DOCKER_HOST string into a net dialer and the
// base origin URL the agent's reverse proxy should target.
package dockerhost

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"time"
)

type DialFunc = func(ctx context.Context, network, addr string) (net.Conn, error)

func DialContextFor(host string) (DialFunc, string, error) {
	u, err := url.Parse(host)
	if err != nil {
		return nil, "", fmt.Errorf("parse DOCKER_HOST %q: %w", host, err)
	}
	switch u.Scheme {
	case "unix":
		socket := u.Path
		dial := func(ctx context.Context, _, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 10 * time.Second}
			return d.DialContext(ctx, "unix", socket)
		}
		return dial, "http://docker", nil
	case "tcp":
		addr := u.Host
		dial := func(ctx context.Context, _, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 10 * time.Second}
			return d.DialContext(ctx, "tcp", addr)
		}
		return dial, "http://" + addr, nil
	default:
		return nil, "", fmt.Errorf("unsupported DOCKER_HOST scheme %q (Phase 0 supports unix and tcp)", u.Scheme)
	}
}
