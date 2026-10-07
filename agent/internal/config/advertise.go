package config

import (
	"errors"
	"fmt"
	"net"
	"net/url"
	"strconv"
	"strings"
	"unicode"
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
// known. Such a URL is a scheme, a host and perhaps a port, nothing else:
// what phones are told is an address, so a path, a query, a fragment or a
// user name would be lost.
//
// A value that cannot be right is refused, with an error that names it and
// says what is wrong with it, instead of ending up in pairing codes that
// lead nowhere.
func ParseAdvertise(value string, insecure bool, listenPort string) (Advertise, error) {
	value = strings.TrimSpace(value)
	if !insecure {
		if value == "" {
			return Advertise{Port: listenPort}, nil
		}
		if strings.Contains(value, "://") {
			return Advertise{}, fmt.Errorf("AGENT_ADVERTISE %q: give host or host:port, without a scheme", value)
		}
		host, port, err := splitAddress(value)
		if err != nil {
			return Advertise{}, refused("AGENT_ADVERTISE", value, err)
		}
		if port == "" {
			port = listenPort
		}
		return Advertise{Host: host, Port: port}, nil
	}
	if value == "" {
		return Advertise{Scheme: "http", Port: listenPort}, nil
	}
	if strings.IndexFunc(value, unicode.IsSpace) >= 0 {
		return Advertise{}, fmt.Errorf("AGENT_ADVERTISE %q: a URL must not contain white space", value)
	}
	notAProxyURL := fmt.Errorf("AGENT_ADVERTISE %q: with --insecure-http give the URL of the proxy in front, such as https://docker.example.com", value)
	if !strings.Contains(value, "://") {
		return Advertise{}, notAProxyURL
	}
	u, err := url.Parse(value)
	if err != nil {
		// The cause alone: the error of the parser repeats the value.
		var parse *url.Error
		if errors.As(err, &parse) {
			err = parse.Err
		}
		return Advertise{}, fmt.Errorf("AGENT_ADVERTISE %q: %v", value, err)
	}
	if (u.Scheme != "https" && u.Scheme != "http") || u.Host == "" {
		return Advertise{}, notAProxyURL
	}
	wrong := ""
	switch {
	case u.User != nil:
		wrong = "the URL must not carry a user name or a password"
	case u.RawQuery != "" || u.ForceQuery:
		wrong = "the URL must not have a query, the part from the ? on"
	case u.Fragment != "" || strings.Contains(value, "#"):
		wrong = "the URL must not have a fragment, the part from the # on"
	case u.Path != "" && u.Path != "/":
		wrong = fmt.Sprintf("the URL must not have a path, and has %q: the proxy has to serve the agent at the root of its address", u.Path)
	}
	if wrong != "" {
		return Advertise{}, fmt.Errorf("AGENT_ADVERTISE %q: %s", value, wrong)
	}
	host, port, err := splitAddress(u.Host)
	if err != nil {
		return Advertise{}, refused("AGENT_ADVERTISE", value, err)
	}
	if port == "" {
		port = "443"
		if u.Scheme == "http" {
			port = "80"
		}
	}
	return Advertise{Scheme: u.Scheme, Host: host, Port: port}, nil
}

// WithHost returns a with its host (and port, if given) replaced by an
// address typed on the command line. It refuses what ParseAdvertise refuses
// in a host and a port.
func (a Advertise) WithHost(hostPort string) (Advertise, error) {
	hostPort = strings.TrimSpace(hostPort)
	if hostPort == "" {
		return a, nil
	}
	if strings.Contains(hostPort, "://") {
		return Advertise{}, fmt.Errorf("--host %q: give host or host:port, without a scheme", hostPort)
	}
	host, port, err := splitAddress(hostPort)
	if err != nil {
		return Advertise{}, refused("--host", hostPort, err)
	}
	if port == "" {
		port = a.Port
	}
	a.Host, a.Port = host, port
	return a, nil
}

// errNoHost means an address has no host in it.
var errNoHost = errors.New("no host")

// refused names a value that was turned down and says why.
func refused(what, value string, err error) error {
	if errors.Is(err, errNoHost) {
		return fmt.Errorf("%s %q has no host", what, value)
	}
	return fmt.Errorf("%s %q: %v", what, value, err)
}

// splitAddress reads a host, or a host and a port, the way a person types
// them: a name or an IPv4 address, with :port after it if there is one, or
// an IPv6 address, which needs brackets around it when a port follows. port
// is empty when the value carries none. The error says what is wrong with
// the value and leaves naming it to the caller.
func splitAddress(value string) (host, port string, err error) {
	withPort := false
	switch {
	case strings.HasPrefix(value, "["):
		end := strings.IndexByte(value, ']')
		if end < 0 {
			return "", "", errors.New("the opening bracket has no closing bracket")
		}
		host = value[1:end]
		if rest := value[end+1:]; rest != "" {
			if rest[0] != ':' {
				return "", "", errors.New("after the closing bracket only a colon and a port may follow")
			}
			port, withPort = rest[1:], true
		}
	case net.ParseIP(value) != nil || !strings.Contains(value, ":"):
		// A name or an address by itself. An IPv6 address has colons of its
		// own, so without brackets none of them can start a port.
		host = value
	case strings.Count(value, ":") == 1:
		host, port, _ = strings.Cut(value, ":")
		withPort = true
	default:
		return "", "", errors.New("it has more than one colon and is not an IPv6 address; with a port, an IPv6 address is written [address]:port")
	}
	if err := checkHost(host); err != nil {
		return "", "", err
	}
	if withPort {
		if err := checkPort(port); err != nil {
			return "", "", err
		}
	}
	return host, port, nil
}

// checkHost refuses a host that no phone could connect to: an empty one, one
// with a character that belongs to another part of a URL or was left over
// from a bracket, and one with a colon that is not an IP address.
func checkHost(host string) error {
	if host == "" {
		return errNoHost
	}
	if i := strings.IndexAny(host, "/?#@[]"); i >= 0 {
		return fmt.Errorf("the host must not contain %q", host[i:i+1])
	}
	if strings.IndexFunc(host, unicode.IsSpace) >= 0 {
		return errors.New("the host must not contain white space")
	}
	if strings.Contains(host, ":") && net.ParseIP(host) == nil {
		return errors.New("the host has a colon in it and is not an IP address")
	}
	return nil
}

// checkPort refuses a port that is not a number from 1 to 65535. It is
// called only when a colon announced a port.
func checkPort(port string) error {
	if port == "" {
		return errors.New("there is a colon with no port after it")
	}
	if n, err := strconv.ParseUint(port, 10, 16); err != nil || n == 0 {
		return fmt.Errorf("the port %q is not a number from 1 to 65535", port)
	}
	return nil
}
