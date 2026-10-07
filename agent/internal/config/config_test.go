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
	if err == nil || !strings.Contains(err.Error(), "AGENT_TOKEN is too short") {
		t.Fatalf("err = %v", err)
	}
	// The error ends up in a log, where neither the token nor its length
	// belongs.
	if strings.Contains(err.Error(), "15") || strings.Contains(err.Error(), "fifteen") {
		t.Fatalf("the error gives away the token or its length: %v", err)
	}
}

func TestASharedTokenWithWhiteSpaceAroundItOrAControlCharacterStopsTheAgent(t *testing.T) {
	const token = "sEcReT-0123456789abcdef"
	for name, c := range map[string]struct{ value, wrong string }{
		"a carriage return at the end": {token + "\r", "ends with white space"},
		"a line feed at the end":       {token + "\n", "ends with white space"},
		"a space at the end":           {token + " ", "ends with white space"},
		"a space at the start":         {" " + token, "starts with white space"},
		"a tab at the start":           {"\t" + token, "starts with white space"},
		"a zero byte inside":           {"sEcReT-01234\x0056789abcdef", "contains a control character"},
		"a line feed inside":           {"sEcReT-01234\n56789abcdef", "contains a control character"},
		"nothing but white space":      {"   ", "starts with white space"},
		// Fifteen characters and a carriage return: that must neither pass
		// for sixteen nor be called short.
		"a short one with a carriage return": {"sEcReT-01234567\r", "ends with white space"},
	} {
		_, err := Load(env("AGENT_TOKEN", c.value), false)
		if err == nil {
			t.Errorf("%s: accepted", name)
			continue
		}
		if !strings.Contains(err.Error(), "AGENT_TOKEN") || !strings.Contains(err.Error(), c.wrong) {
			t.Errorf("%s: err = %v, want one that names AGENT_TOKEN and says that it %s", name, err, c.wrong)
		}
		if strings.Contains(err.Error(), "sEcReT") {
			t.Errorf("%s: the error prints the token: %v", name, err)
		}
	}
	// White space inside a token is the user's choice.
	if _, err := Load(env("AGENT_TOKEN", "correct horse battery staple"), false); err != nil {
		t.Fatalf("a token with spaces inside: %v", err)
	}
}

func TestTheSwitchForPlainHTTPIsReadStrictly(t *testing.T) {
	for _, v := range []string{"1", "true", "TRUE", "yes", "Yes", "on", " ON "} {
		cfg, err := Load(env("AGENT_INSECURE_HTTP", v), false)
		if err != nil || !cfg.InsecureHTTP {
			t.Errorf("%q: plain HTTP = %v, err = %v; want it on", v, cfg.InsecureHTTP, err)
		}
	}
	for _, v := range []string{"", "  ", "0", "false", "False", "no", "off", " OFF "} {
		cfg, err := Load(env("AGENT_INSECURE_HTTP", v), false)
		if err != nil || cfg.InsecureHTTP {
			t.Errorf("%q: plain HTTP = %v, err = %v; want it off", v, cfg.InsecureHTTP, err)
		}
	}
	for _, v := range []string{"2", "enabled", "tru", "y", "of"} {
		// With the flag given as well: that does not excuse a mistyped value.
		for _, flag := range []bool{false, true} {
			_, err := Load(env("AGENT_INSECURE_HTTP", v), flag)
			if err == nil || !strings.Contains(err.Error(), "AGENT_INSECURE_HTTP") || !strings.Contains(err.Error(), `"`+v+`"`) {
				t.Errorf("%q (flag %v): err = %v, want one that names AGENT_INSECURE_HTTP and the value", v, flag, err)
			}
		}
	}
}

func TestABadAdvertisedAddressIsAnErrorThatNamesTheVariable(t *testing.T) {
	_, err := Load(env("AGENT_ADVERTISE", "my-server.lan:99999"), false)
	if err == nil || !strings.Contains(err.Error(), "AGENT_ADVERTISE") || !strings.Contains(err.Error(), "99999") {
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
