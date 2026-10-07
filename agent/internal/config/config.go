// Package config loads the agent's runtime configuration from the environment.
package config

import (
	"errors"
	"fmt"
	"net"
	"strings"

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
	cfg := Config{
		ListenAddr:   getenv("AGENT_LISTEN"),
		DockerHost:   getenv("DOCKER_HOST"),
		InsecureHTTP: insecureFlag || truthy(getenv("AGENT_INSECURE_HTTP")),
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
	if n := len(cfg.LegacyToken); n > 0 && n < MinLegacyToken {
		return Config{}, fmt.Errorf("AGENT_TOKEN is too short (%d characters): use at least %d, or remove it and pair devices instead", n, MinLegacyToken)
	}
	if state.IsDeviceToken(cfg.LegacyToken) {
		return Config{}, errors.New("AGENT_TOKEN must not start with \"dm1.\": that prefix marks the tokens of paired devices")
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

func truthy(v string) bool {
	switch strings.ToLower(strings.TrimSpace(v)) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}
