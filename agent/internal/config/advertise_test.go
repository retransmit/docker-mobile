package config

import "testing"

func TestParseAdvertisePinned(t *testing.T) {
	cases := map[string]Advertise{
		"":                    {Port: "8443"},
		"my-server.lan":       {Host: "my-server.lan", Port: "8443"},
		"my-server.lan:9443":  {Host: "my-server.lan", Port: "9443"},
		"192.168.1.20":        {Host: "192.168.1.20", Port: "8443"},
		"[fd00::1]:9443":      {Host: "fd00::1", Port: "9443"},
		"[fd00::1]":           {Host: "fd00::1", Port: "8443"},
		"  my-server.lan:1  ": {Host: "my-server.lan", Port: "1"},
	}
	for in, want := range cases {
		got, err := ParseAdvertise(in, false, "8443")
		if err != nil || got != want {
			t.Errorf("ParseAdvertise(%q) = %+v, %v, want %+v", in, got, err, want)
		}
	}
	for _, bad := range []string{"https://my-server.lan", ":8443"} {
		if _, err := ParseAdvertise(bad, false, "8443"); err == nil {
			t.Errorf("ParseAdvertise(%q) was accepted", bad)
		}
	}
}

func TestParseAdvertiseBehindAProxy(t *testing.T) {
	cases := map[string]Advertise{
		"":                                {Scheme: "http", Port: "8080"},
		"https://docker.example.com":      {Scheme: "https", Host: "docker.example.com", Port: "443"},
		"https://docker.example.com:8443": {Scheme: "https", Host: "docker.example.com", Port: "8443"},
		"http://10.0.0.5":                 {Scheme: "http", Host: "10.0.0.5", Port: "80"},
		"http://10.0.0.5:8080":            {Scheme: "http", Host: "10.0.0.5", Port: "8080"},
	}
	for in, want := range cases {
		got, err := ParseAdvertise(in, true, "8080")
		if err != nil || got != want {
			t.Errorf("ParseAdvertise(%q) = %+v, %v, want %+v", in, got, err, want)
		}
	}
	for _, bad := range []string{"docker.example.com", "ftp://docker.example.com", "https://"} {
		if _, err := ParseAdvertise(bad, true, "8080"); err == nil {
			t.Errorf("ParseAdvertise(%q) was accepted", bad)
		}
	}
}

func TestWithHostOverridesTheAdvertisedAddress(t *testing.T) {
	base := Advertise{Host: "old", Port: "8443"}
	cases := map[string]Advertise{
		"":               base,
		"new.lan":        {Host: "new.lan", Port: "8443"},
		"new.lan:9000":   {Host: "new.lan", Port: "9000"},
		"[fd00::2]:9000": {Host: "fd00::2", Port: "9000"},
	}
	for in, want := range cases {
		got, err := base.WithHost(in)
		if err != nil || got != want {
			t.Errorf("WithHost(%q) = %+v, %v, want %+v", in, got, err, want)
		}
	}
	proxied := Advertise{Scheme: "https", Host: "docker.example.com", Port: "443"}
	if got, _ := proxied.WithHost("other.example.com"); got != (Advertise{Scheme: "https", Host: "other.example.com", Port: "443"}) {
		t.Errorf("WithHost on a proxied address = %+v", got)
	}
	for _, bad := range []string{"https://new.lan", ":9000"} {
		if _, err := base.WithHost(bad); err == nil {
			t.Errorf("WithHost(%q) was accepted", bad)
		}
	}
}
