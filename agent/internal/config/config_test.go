package config

import "testing"

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoadDefaults(t *testing.T) {
	cfg, err := Load(env(map[string]string{"AGENT_TOKEN": "secret"}))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.ListenAddr != ":8080" {
		t.Errorf("ListenAddr = %q, want :8080", cfg.ListenAddr)
	}
	if cfg.DockerHost != "unix:///var/run/docker.sock" {
		t.Errorf("DockerHost = %q, want unix:///var/run/docker.sock", cfg.DockerHost)
	}
	if cfg.Token != "secret" {
		t.Errorf("Token = %q, want secret", cfg.Token)
	}
}

func TestLoadOverrides(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"AGENT_TOKEN":  "t",
		"AGENT_LISTEN": ":9000",
		"DOCKER_HOST":  "tcp://127.0.0.1:2375",
	}))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.ListenAddr != ":9000" || cfg.DockerHost != "tcp://127.0.0.1:2375" {
		t.Errorf("overrides not applied: %+v", cfg)
	}
}

func TestLoadRequiresToken(t *testing.T) {
	if _, err := Load(env(map[string]string{})); err == nil {
		t.Fatal("expected error when AGENT_TOKEN is missing")
	}
}
