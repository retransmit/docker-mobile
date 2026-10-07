package config

import (
	"fmt"
	"net"
	"net/url"
	"strings"
)

// Advertise is the address pairing codes carry. Every field may be empty.
type Advertise struct {
	// Scheme is "https" or "http" in plain-HTTP mode, and empty when the
	// agent serves its own pinned certificate.
	Scheme string
	Host   string
	Port   string
}

// ParseAdvertise reads an advertised address.
//
// With the agent's own certificate (insecure false) the value is host or
// host:port; the port defaults to the one the agent listens on.
//
// In plain-HTTP mode the value is the URL of the proxy in front, such as
// https://docker.example.com; without a value only the scheme "http" is
// known.
func ParseAdvertise(value string, insecure bool, listenPort string) (Advertise, error) {
	value = strings.TrimSpace(value)
	if !insecure {
		if value == "" {
			return Advertise{Port: listenPort}, nil
		}
		if strings.Contains(value, "://") {
			return Advertise{}, fmt.Errorf("AGENT_ADVERTISE %q: give host or host:port, without a scheme", value)
		}
		host, port, err := net.SplitHostPort(value)
		if err != nil {
			// No port: the whole value is the host (an IPv6 literal may be
			// in brackets).
			host, port = strings.Trim(value, "[]"), listenPort
		}
		if host == "" {
			return Advertise{}, fmt.Errorf("AGENT_ADVERTISE %q has no host", value)
		}
		return Advertise{Host: host, Port: port}, nil
	}
	if value == "" {
		return Advertise{Scheme: "http", Port: listenPort}, nil
	}
	u, err := url.Parse(value)
	if err != nil || (u.Scheme != "https" && u.Scheme != "http") || u.Hostname() == "" {
		return Advertise{}, fmt.Errorf("AGENT_ADVERTISE %q: with --insecure-http give the URL of the proxy in front, such as https://docker.example.com", value)
	}
	port := u.Port()
	if port == "" {
		port = "443"
		if u.Scheme == "http" {
			port = "80"
		}
	}
	return Advertise{Scheme: u.Scheme, Host: u.Hostname(), Port: port}, nil
}

// WithHost returns a with its host (and port, if given) replaced by an
// address typed on the command line.
func (a Advertise) WithHost(hostPort string) (Advertise, error) {
	hostPort = strings.TrimSpace(hostPort)
	if hostPort == "" {
		return a, nil
	}
	if strings.Contains(hostPort, "://") {
		return Advertise{}, fmt.Errorf("--host %q: give host or host:port, without a scheme", hostPort)
	}
	host, port, err := net.SplitHostPort(hostPort)
	if err != nil {
		host, port = strings.Trim(hostPort, "[]"), a.Port
	}
	if host == "" {
		return Advertise{}, fmt.Errorf("--host %q has no host", hostPort)
	}
	a.Host, a.Port = host, port
	return a, nil
}
