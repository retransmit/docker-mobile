package auth

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"testing"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/conns"
	"github.com/retransmit/docker-mobile/agent/internal/state"
	"github.com/retransmit/docker-mobile/agent/internal/throttle"
)

type clock struct{ t time.Time }

func (c *clock) now() time.Time { return c.t }

type fixture struct {
	auth    *Authenticator
	devices *state.Devices
	clock   *clock
	seen    []state.Device // callers the inner handler saw
	failed  []string
}

func newFixture(t *testing.T, legacy string) *fixture {
	t.Helper()
	dir, err := state.Open(filepath.Join(t.TempDir(), "data"))
	if err != nil {
		t.Fatal(err)
	}
	c := &clock{t: time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)}
	devices, err := state.LoadDevices(dir, c.now)
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{devices: devices, clock: c}
	f.auth = &Authenticator{
		Devices:   devices,
		Legacy:    legacy,
		Limiter:   throttle.New(c.now),
		Conns:     conns.New(),
		OnFailure: func(remote string) { f.failed = append(f.failed, remote) },
	}
	return f
}

func (f *fixture) do(bearer, remote string) *httptest.ResponseRecorder {
	h := f.auth.Require(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		dev, _ := Caller(r.Context())
		f.seen = append(f.seen, dev)
		w.WriteHeader(http.StatusOK)
	}))
	req := httptest.NewRequest(http.MethodGet, "/containers/json", nil)
	if bearer != "" {
		req.Header.Set("Authorization", bearer)
	}
	if remote != "" {
		req.RemoteAddr = remote
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec
}

const legacy = "a-shared-token-of-enough-length"

func TestADeviceTokenIdentifiesItsDevice(t *testing.T) {
	f := newFixture(t, "")
	dev, token, _ := f.devices.Add("Pixel 8", state.RoleReadOnly)
	if rec := f.do("Bearer "+token, ""); rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	if len(f.seen) != 1 || f.seen[0].ID != dev.ID || f.seen[0].Role != state.RoleReadOnly {
		t.Fatalf("caller = %+v", f.seen)
	}
}

func TestTheSharedTokenIsAFullDeviceCalledEnvToken(t *testing.T) {
	f := newFixture(t, legacy)
	if rec := f.do("Bearer "+legacy, ""); rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	got := f.seen[0]
	if got.ID != LegacyDeviceID || got.Name != "env-token" || got.Role != state.RoleFull {
		t.Fatalf("caller = %+v", got)
	}
}

func TestBadCredentialsAreRefusedWithAJSONMessage(t *testing.T) {
	f := newFixture(t, legacy)
	_, token, _ := f.devices.Add("phone", state.RoleFull)
	for name, bearer := range map[string]string{
		"nothing":            "",
		"empty bearer":       "Bearer ",
		"wrong shared token": "Bearer nope",
		"wrong scheme":       "Basic " + legacy,
		"no scheme":          legacy,
		"damaged device":     "Bearer " + token + "x",
		"unknown device":     "Bearer dm1.ffffffff.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
		"lower case scheme":  "bearer " + legacy,
	} {
		rec := f.do(bearer, "")
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s: code = %d, want 401", name, rec.Code)
		}
		var body map[string]string
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body["message"] != "unauthorized" {
			t.Errorf("%s: body = %q", name, rec.Body.String())
		}
	}
	if len(f.seen) != 0 {
		t.Fatalf("the handler ran for %d refused requests", len(f.seen))
	}
}

func TestWithoutASharedTokenNothingButDevicesGetsIn(t *testing.T) {
	f := newFixture(t, "")
	for _, bearer := range []string{"Bearer ", "Bearer anything", ""} {
		if rec := f.do(bearer, ""); rec.Code != http.StatusUnauthorized {
			t.Fatalf("%q: code = %d, want 401", bearer, rec.Code)
		}
	}
}

func TestTenFailuresBlockTheAddressButNotItsPairedDevices(t *testing.T) {
	f := newFixture(t, legacy)
	_, token, _ := f.devices.Add("phone", state.RoleFull)
	const nat = "203.0.113.7:40000"
	for i := 0; i < throttle.Threshold; i++ {
		if rec := f.do("Bearer wrong", nat); rec.Code != http.StatusUnauthorized {
			t.Fatalf("failure %d: code = %d", i+1, rec.Code)
		}
	}
	// The right shared token is now refused unseen.
	rec := f.do("Bearer "+legacy, "203.0.113.7:40001")
	if rec.Code != http.StatusTooManyRequests {
		t.Fatalf("code = %d, want 429", rec.Code)
	}
	if got := rec.Header().Get("Retry-After"); got != "60" {
		t.Fatalf("Retry-After = %q, want 60", got)
	}
	// A paired device behind the same address still gets in.
	if rec := f.do("Bearer "+token, nat); rec.Code != http.StatusOK {
		t.Fatalf("paired device: code = %d, want 200", rec.Code)
	}
	// Another address is not affected.
	if rec := f.do("Bearer "+legacy, "198.51.100.9:1"); rec.Code != http.StatusOK {
		t.Fatalf("other address: code = %d, want 200", rec.Code)
	}
	// Blocked requests are not counted as further failures.
	if len(f.failed) != throttle.Threshold {
		t.Fatalf("%d failures reported, want %d", len(f.failed), throttle.Threshold)
	}
	// When the block ends the shared token works again.
	f.clock.t = f.clock.t.Add(time.Minute)
	if rec := f.do("Bearer "+legacy, nat); rec.Code != http.StatusOK {
		t.Fatalf("after the block: code = %d, want 200", rec.Code)
	}
}

func TestClosingADeviceEndsItsOpenRequest(t *testing.T) {
	f := newFixture(t, "")
	dev, token, _ := f.devices.Add("phone", state.RoleFull)
	started := make(chan struct{})
	ended := make(chan error, 1)
	h := f.auth.Require(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		<-r.Context().Done()
		ended <- r.Context().Err()
	}))
	req := httptest.NewRequest(http.MethodGet, "/events", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	go h.ServeHTTP(httptest.NewRecorder(), req)
	<-started
	if f.auth.Conns.Open(dev.ID) != 1 {
		t.Fatalf("open = %d, want 1", f.auth.Conns.Open(dev.ID))
	}
	f.auth.Conns.CloseDevice(dev.ID)
	select {
	case err := <-ended:
		if err != context.Canceled {
			t.Fatalf("err = %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the request did not end")
	}
}

func TestOnCallerLearnsWhoARequestBelongsTo(t *testing.T) {
	f := newFixture(t, "")
	dev, token, _ := f.devices.Add("phone", state.RoleFull)
	var told string
	f.auth.OnCaller = func(_ *http.Request, d state.Device) { told = d.ID }
	f.do("Bearer "+token, "")
	if told != dev.ID {
		t.Fatalf("OnCaller got %q, want %q", told, dev.ID)
	}
}
