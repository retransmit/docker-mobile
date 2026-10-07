package config

import (
	"strconv"
	"strings"
	"testing"
)

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

// refusal is a value that must be turned down, with words the error must use
// to say what is wrong with it.
type refusal struct{ in, says string }

// check fails the test unless err turns the value down, names it and says
// what is wrong with it.
func (r refusal) check(t *testing.T, call string, got Advertise, err error) {
	t.Helper()
	switch {
	case err == nil:
		t.Errorf("%s(%q) was accepted as %+v", call, r.in, got)
	case !strings.Contains(err.Error(), strconv.Quote(r.in)):
		t.Errorf("%s(%q): the error does not name the value: %v", call, r.in, err)
	case !strings.Contains(err.Error(), r.says):
		t.Errorf("%s(%q): the error does not say %q: %v", call, r.in, r.says, err)
	}
}

func TestParseAdvertisePinnedRefusesWhatCannotBeRight(t *testing.T) {
	for _, r := range []refusal{
		{"my-server.lan:", "no port after it"},
		{"my-server.lan:8443:", "more than one colon"},
		{"my-server.lan:abc", "not a number from 1 to 65535"},
		{"my-server.lan:0", "not a number from 1 to 65535"},
		{"my-server.lan:65536", "not a number from 1 to 65535"},
		{"my-server.lan:99999", "not a number from 1 to 65535"},
		{"my-server.lan:-1", "not a number from 1 to 65535"},
		{"my-server.lan:+80", "not a number from 1 to 65535"},
		{"my-server.lan:8443/agent", "not a number from 1 to 65535"},
		{"my-server.lan/agent", `must not contain "/"`},
		{"my-server.lan?x=1", `must not contain "?"`},
		{"my-server.lan#top", `must not contain "#"`},
		{"admin@my-server.lan", `must not contain "@"`},
		{"my-server.lan]", `must not contain "]"`},
		{"my server.lan", "white space"},
		{"my-server.lan: 8443", "not a number from 1 to 65535"},
		{"[fd00::1", "bracket"},
		{"[fd00::1]9443", "bracket"},
		{"[fd00::1]:", "no port after it"},
		{"[fd00::1]:0", "not a number from 1 to 65535"},
		{"[my:server]:8443", "not an IP address"},
		{"fd00::1:", "more than one colon"},
		{"a:b:c", "more than one colon"},
		{"[]:8443", "no host"},
		{":8443", "no host"},
		{"https://my-server.lan", "without a scheme"},
	} {
		got, err := ParseAdvertise(r.in, false, "8443")
		r.check(t, "ParseAdvertise", got, err)
	}
}

func TestParseAdvertiseBehindAProxyRefusesWhatCannotBeRight(t *testing.T) {
	for _, r := range []refusal{
		{"https://docker.example.com/agent", "path"},
		{"https://docker.example.com/agent/", "path"},
		{"https://docker.example.com//", "path"},
		{"https://user:secret@docker.example.com", "user name"},
		{"https://user@docker.example.com", "user name"},
		{"https://@docker.example.com", "user name"},
		{"https://docker.example.com?x=1", "query"},
		{"https://docker.example.com/?x=1", "query"},
		{"https://docker.example.com?", "query"},
		{"https://docker.example.com#top", "fragment"},
		{"https://docker.example.com/#", "fragment"},
		{"https://docker.example.com:", "no port after it"},
		{"https://docker.example.com:0", "not a number from 1 to 65535"},
		{"https://docker.example.com:65536", "not a number from 1 to 65535"},
		{"https://docker.example.com:abc", "port"},
		{"https://[fd00::1]:", "no port after it"},
		{"https://docker example.com", "white space"},
		{"docker.example.com", "the URL of the proxy"},
		{"docker.example.com:8443", "the URL of the proxy"},
		{"ftp://docker.example.com", "the URL of the proxy"},
		{"https://", "the URL of the proxy"},
		{"https:///agent", "the URL of the proxy"},
	} {
		got, err := ParseAdvertise(r.in, true, "8080")
		r.check(t, "ParseAdvertise", got, err)
	}
}

func TestWithHostRefusesWhatCannotBeRight(t *testing.T) {
	base := Advertise{Host: "old", Port: "8443"}
	for _, r := range []refusal{
		{"new.lan:", "no port after it"},
		{"new.lan:9000:", "more than one colon"},
		{"new.lan:abc", "not a number from 1 to 65535"},
		{"new.lan:0", "not a number from 1 to 65535"},
		{"new.lan:65536", "not a number from 1 to 65535"},
		{"new.lan/x", `must not contain "/"`},
		{"new.lan?x", `must not contain "?"`},
		{"new.lan#x", `must not contain "#"`},
		{"user@new.lan", `must not contain "@"`},
		{"new.lan]", `must not contain "]"`},
		{"new lan", "white space"},
		{"[fd00::2", "bracket"},
		{"[fd00::2]9000", "bracket"},
		{"[fd00::2]:", "no port after it"},
		{"[new:lan]:9000", "not an IP address"},
		{"a:b:c", "more than one colon"},
		{":9000", "no host"},
		{"https://new.lan", "without a scheme"},
	} {
		got, err := base.WithHost(r.in)
		r.check(t, "WithHost", got, err)
	}
}

func TestAnIPv6AddressIsReadWithAndWithoutBracketsAndPort(t *testing.T) {
	for in, want := range map[string]Advertise{
		"fd00::1":        {Host: "fd00::1", Port: "8443"},
		"[fd00::1]":      {Host: "fd00::1", Port: "8443"},
		"[fd00::1]:9443": {Host: "fd00::1", Port: "9443"},
		"::1":            {Host: "::1", Port: "8443"},
		// Without brackets all of it is the address, the last group too.
		"2001:db8::9443": {Host: "2001:db8::9443", Port: "8443"},
	} {
		if got, err := ParseAdvertise(in, false, "8443"); err != nil || got != want {
			t.Errorf("ParseAdvertise(%q) = %+v, %v, want %+v", in, got, err, want)
		}
	}
	for in, want := range map[string]Advertise{
		"https://[fd00::1]":      {Scheme: "https", Host: "fd00::1", Port: "443"},
		"https://[fd00::1]:8443": {Scheme: "https", Host: "fd00::1", Port: "8443"},
		"http://[fd00::1]/":      {Scheme: "http", Host: "fd00::1", Port: "80"},
	} {
		if got, err := ParseAdvertise(in, true, "8080"); err != nil || got != want {
			t.Errorf("ParseAdvertise(%q) = %+v, %v, want %+v", in, got, err, want)
		}
	}
	base := Advertise{Host: "old", Port: "8443"}
	for in, want := range map[string]Advertise{
		"fd00::2":        {Host: "fd00::2", Port: "8443"},
		"[fd00::2]":      {Host: "fd00::2", Port: "8443"},
		"[fd00::2]:9000": {Host: "fd00::2", Port: "9000"},
	} {
		if got, err := base.WithHost(in); err != nil || got != want {
			t.Errorf("WithHost(%q) = %+v, %v, want %+v", in, got, err, want)
		}
	}
}

func TestAddressesAtTheEdgeOfWhatIsRightAreAccepted(t *testing.T) {
	for in, want := range map[string]Advertise{
		"my-server.lan:1":     {Host: "my-server.lan", Port: "1"},
		"my-server.lan:65535": {Host: "my-server.lan", Port: "65535"},
		"192.168.1.20:9443":   {Host: "192.168.1.20", Port: "9443"},
	} {
		if got, err := ParseAdvertise(in, false, "8443"); err != nil || got != want {
			t.Errorf("ParseAdvertise(%q) = %+v, %v, want %+v", in, got, err, want)
		}
	}
	for in, want := range map[string]Advertise{
		// A lone slash is no path: the proxy serves the agent at its root.
		"https://docker.example.com/":      {Scheme: "https", Host: "docker.example.com", Port: "443"},
		"https://docker.example.com:8443/": {Scheme: "https", Host: "docker.example.com", Port: "8443"},
		"https://docker.example.com:65535": {Scheme: "https", Host: "docker.example.com", Port: "65535"},
	} {
		if got, err := ParseAdvertise(in, true, "8080"); err != nil || got != want {
			t.Errorf("ParseAdvertise(%q) = %+v, %v, want %+v", in, got, err, want)
		}
	}
	// The port the agent listens on is the caller's and is not judged here.
	if got, err := ParseAdvertise("my-server.lan", false, "0"); err != nil || got != (Advertise{Host: "my-server.lan", Port: "0"}) {
		t.Errorf("ParseAdvertise with listen port 0 = %+v, %v", got, err)
	}
}
