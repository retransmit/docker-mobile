// Package config loads the agent's runtime configuration from the environment.
package config

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"unicode"

	"github.com/retransmit/docker-mobile/agent/internal/state"
)

const (
	// MinLegacyToken is the shortest shared token the agent accepts.
	MinLegacyToken = 16
	// WeakLegacyToken is the length below which the agent warns.
	WeakLegacyToken = 32

	defaultTLSListen   = ":8443"
	defaultPlainListen = ":8080"
	defaultDockerHost  = "unix:///var/run/docker.sock"
	defaultDataDir     = "/var/lib/docker-mobile-agent"
)

// Config is everything the agent reads from its environment.
type Config struct {
	ListenAddr string
	DockerHost string
	DataDir    string
	// Advertise is where phones reach the agent, for pairing codes.
	Advertise Advertise
	// InsecureHTTP serves plain HTTP, for use behind a proxy that does TLS.
	InsecureHTTP bool
	// LegacyToken is the shared token from AGENT_TOKEN; empty when unset.
	LegacyToken string
	// Name is how the agent calls itself in pairing codes (AGENT_NAME);
	// empty means the host name.
	Name string
}

// Load builds a Config from getenv. insecureFlag is the --insecure-http
// flag; AGENT_INSECURE_HTTP=1 means the same.
func Load(getenv func(string) string, insecureFlag bool) (Config, error) {
	insecureEnv, err := onOff("AGENT_INSECURE_HTTP", getenv("AGENT_INSECURE_HTTP"))
	if err != nil {
		return Config{}, err
	}
	cfg := Config{
		ListenAddr:   getenv("AGENT_LISTEN"),
		DockerHost:   getenv("DOCKER_HOST"),
		InsecureHTTP: insecureFlag || insecureEnv,
		LegacyToken:  getenv("AGENT_TOKEN"),
		Name:         strings.TrimSpace(getenv("AGENT_NAME")),
	}
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = defaultTLSListen
		if cfg.InsecureHTTP {
			cfg.ListenAddr = defaultPlainListen
		}
	}
	if cfg.DockerHost == "" {
		cfg.DockerHost = defaultDockerHost
	}
	cfg.DataDir = DataDir(getenv)
	if err := checkLegacyToken(cfg.LegacyToken); err != nil {
		return Config{}, err
	}
	_, listenPort, err := net.SplitHostPort(cfg.ListenAddr)
	if err != nil {
		return Config{}, fmt.Errorf("AGENT_LISTEN %q is not host:port: %v", cfg.ListenAddr, err)
	}
	cfg.Advertise, err = ParseAdvertise(getenv("AGENT_ADVERTISE"), cfg.InsecureHTTP, listenPort)
	if err != nil {
		return Config{}, err
	}
	return cfg, nil
}

// DataDir returns the state folder alone, for commands that need nothing
// else from the configuration.
func DataDir(getenv func(string) string) string {
	if dir := getenv("AGENT_DATA"); dir != "" {
		return dir
	}
	return defaultDataDir
}

// checkLegacyToken refuses a shared token that is too short, that could not
// match, or that would be taken for the token of a device. No token at all
// is fine. Its errors say what is wrong without the token and without its
// length: they end up in a log, and the authentication takes care that the
// length cannot be learned from outside.
func checkLegacyToken(token string) error {
	if token == "" {
		return nil
	}
	// A phone sends neither white space around its token nor a control
	// character in it, so no request would ever match such a token, with
	// nothing but a 401 to show for it. The usual cause is the carriage
	// return that an env file written on Windows leaves at the end of the
	// line. This comes before the length: the hidden character would count
	// toward it.
	wrong := ""
	switch {
	case strings.TrimLeftFunc(token, unicode.IsSpace) != token:
		wrong = "starts with white space"
	case strings.TrimRightFunc(token, unicode.IsSpace) != token:
		wrong = "ends with white space"
	case strings.IndexFunc(token, unicode.IsControl) >= 0:
		wrong = "contains a control character"
	}
	if wrong != "" {
		return fmt.Errorf("AGENT_TOKEN %s: a phone does not send that, so the token would never match; look for a stray space or a line ending in the value", wrong)
	}
	if len(token) < MinLegacyToken {
		return fmt.Errorf("AGENT_TOKEN is too short: use at least %d characters, or remove it and pair devices instead", MinLegacyToken)
	}
	if state.IsDeviceToken(token) {
		return errors.New("AGENT_TOKEN must not start with \"dm1.\": that prefix marks the tokens of paired devices")
	}
	return nil
}

// onOff reads a switch from the environment. No value is off; 1, true, yes
// and on are on; 0, false, no and off are off, in any case and with white
// space around them. Anything else is an error that names the variable and
// the value: a mistyped switch must not pass for off.
func onOff(name, value string) (bool, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "", "0", "false", "no", "off":
		return false, nil
	case "1", "true", "yes", "on":
		return true, nil
	}
	return false, fmt.Errorf("%s %q is neither on nor off: use 1, true, yes or on, or 0, false, no or off", name, value)
}
