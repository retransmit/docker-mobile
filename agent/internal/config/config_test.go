package config

import (
	"strings"
	"testing"
)

func env(pairs ...string) func(string) string {
	m := map[string]string{}
	for i := 0; i+1 < len(pairs); i += 2 {
		m[pairs[i]] = pairs[i+1]
	}
	return func(k string) string { return m[k] }
}

func TestDefaultsServeTLSOn8443WithoutAnyToken(t *testing.T) {
	cfg, err := Load(env(), false)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	want := Config{
		ListenAddr: ":8443",
		DockerHost: "unix:///var/run/docker.sock",
		DataDir:    "/var/lib/docker-mobile-agent",
		Advertise:  Advertise{Port: "8443"},
	}
	if cfg != want {
		t.Fatalf("cfg = %+v, want %+v", cfg, want)
	}
}

func TestPlainHTTPDefaultsTo8080(t *testing.T) {
	for name, load := range map[string]func() (Config, error){
		"flag": func() (Config, error) { return Load(env(), true) },
		"env":  func() (Config, error) { return Load(env("AGENT_INSECURE_HTTP", "1"), false) },
		"TRUE": func() (Config, error) { return Load(env("AGENT_INSECURE_HTTP", "TRUE"), false) },
	} {
		cfg, err := load()
		if err != nil {
			t.Fatalf("%s: %v", name, err)
		}
		if !cfg.InsecureHTTP || cfg.ListenAddr != ":8080" || cfg.Advertise != (Advertise{Scheme: "http", Port: "8080"}) {
			t.Fatalf("%s: cfg = %+v", name, cfg)
		}
	}
	if cfg, _ := Load(env("AGENT_INSECURE_HTTP", "0"), false); cfg.InsecureHTTP {
		t.Fatal("AGENT_INSECURE_HTTP=0 turned plain HTTP on")
	}
}

func TestEverySettingIsRead(t *testing.T) {
	cfg, err := Load(env(
		"AGENT_LISTEN", "127.0.0.1:9000",
		"DOCKER_HOST", "tcp://127.0.0.1:2375",
		"AGENT_DATA", "/srv/agent",
		"AGENT_ADVERTISE", "my-server.lan",
		"AGENT_TOKEN", "sixteen-chars-ok",
		"AGENT_NAME", " home lab ",
	), false)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	want := Config{
		ListenAddr:  "127.0.0.1:9000",
		DockerHost:  "tcp://127.0.0.1:2375",
		DataDir:     "/srv/agent",
		Advertise:   Advertise{Host: "my-server.lan", Port: "9000"},
		LegacyToken: "sixteen-chars-ok",
		Name:        "home lab",
	}
	if cfg != want {
		t.Fatalf("cfg = %+v, want %+v", cfg, want)
	}
}

func TestAShortSharedTokenStopsTheAgent(t *testing.T) {
	_, err := Load(env("AGENT_TOKEN", "fifteen-chars-x"), false)
	if err == nil || !strings.Contains(err.Error(), "too short (15 characters)") {
		t.Fatalf("err = %v", err)
	}
}

func TestASharedTokenShapedLikeADeviceTokenStopsTheAgent(t *testing.T) {
	_, err := Load(env("AGENT_TOKEN", "dm1.abcd1234.this-would-never-match"), false)
	if err == nil || !strings.Contains(err.Error(), "dm1.") {
		t.Fatalf("err = %v", err)
	}
}

func TestABadListenAddressIsAnError(t *testing.T) {
	if _, err := Load(env("AGENT_LISTEN", "8443"), false); err == nil {
		t.Fatal("a listen address without a port separator was accepted")
	}
}

func TestDataDir(t *testing.T) {
	if got := DataDir(env()); got != "/var/lib/docker-mobile-agent" {
		t.Fatalf("default = %q", got)
	}
	if got := DataDir(env("AGENT_DATA", "/data")); got != "/data" {
		t.Fatalf("DataDir = %q", got)
	}
}
