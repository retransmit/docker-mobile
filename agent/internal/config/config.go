// Package config loads the agent's runtime configuration from the environment.
package config

import "errors"

type Config struct {
	ListenAddr string
	Token      string
	DockerHost string
}

// Load builds a Config from getenv. AGENT_TOKEN is required.
func Load(getenv func(string) string) (Config, error) {
	cfg := Config{
		ListenAddr: getenv("AGENT_LISTEN"),
		Token:      getenv("AGENT_TOKEN"),
		DockerHost: getenv("DOCKER_HOST"),
	}
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = ":8080"
	}
	if cfg.DockerHost == "" {
		cfg.DockerHost = "unix:///var/run/docker.sock"
	}
	if cfg.Token == "" {
		return Config{}, errors.New("AGENT_TOKEN is required")
	}
	return cfg, nil
}
