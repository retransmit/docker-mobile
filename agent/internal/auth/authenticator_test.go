package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/conns"
	"github.com/retransmit/docker-mobile/agent/internal/state"
	"github.com/retransmit/docker-mobile/agent/internal/throttle"
)

// clock is a time source the tests set by hand. Goroutines may share it.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

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

// counted reports how many failures the limiter holds for the address of
// remote. It finds out by adding failures until the address is blocked, so it
// is the last thing a test does with that address.
func (f *fixture) counted(remote string) int {
	key := throttle.Key(remote)
	added := 0
	for added <= throttle.Threshold {
		if _, blocked := f.auth.Limiter.Blocked(key); blocked {
			break
		}
		f.auth.Limiter.Fail(key)
		added++
	}
	return throttle.Threshold - added
}

const legacy = "a-shared-token-of-enough-length"

// noDevice has the shape of a device token and belongs to nobody.
var noDevice = "dm1.ffffffff." + strings.Repeat("A", 43)

func TestADeviceTokenIdentifiesItsDevice(t *testing.T) {
	f := newFixture(t, "")
	dev, token, _ := f.devices.Add("Pixel 8", state.RoleReadOnly)
	if rec := f.do("Bearer "+token, ""); rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	if len(f.seen) != 1 || f.seen[0].ID != dev.ID || f.seen[0].Role != state.RoleReadOnly {
		t.Fatalf("caller = %+v", f.seen)
	}
	if f.seen[0].TokenHash != "" {
		t.Fatal("the hash of the token travelled with the request")
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
	n := 0
	for name, bearer := range map[string]string{
		"nothing":            "",
		"empty bearer":       "Bearer ",
		"wrong shared token": "Bearer nope",
		"wrong scheme":       "Basic " + legacy,
		"no scheme":          legacy,
		"damaged device":     "Bearer " + token + "x",
		"unknown device":     "Bearer " + noDevice,
		"lower case scheme":  "bearer " + legacy,
	} {
		// Each case has its own address, so however many cases there are, none
		// of them is answered by the throttle.
		n++
		rec := f.do(bearer, fmt.Sprintf("198.51.100.%d:1000", n))
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
	// So is a token with the shape of a device token that belongs to nobody.
	if rec := f.do("Bearer "+noDevice, nat); rec.Code != http.StatusTooManyRequests {
		t.Fatalf("unknown device: code = %d, want 429", rec.Code)
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
	f.clock.advance(time.Minute)
	if rec := f.do("Bearer "+legacy, nat); rec.Code != http.StatusOK {
		t.Fatalf("after the block: code = %d, want 200", rec.Code)
	}
}

func TestAFailureIsCountedOnceWithATokenAndNotAtAllWithout(t *testing.T) {
	f := newFixture(t, legacy)
	known, _, _ := f.devices.Add("phone", state.RoleFull)
	gone, goneToken, _ := f.devices.Add("old phone", state.RoleFull)
	if _, ok, err := f.devices.Remove(gone.ID); !ok || err != nil {
		t.Fatalf("remove: ok = %v, err = %v", ok, err)
	}
	cases := []struct {
		name, bearer string
		counted      int // how often the failure counts against the address
	}{
		// No bearer token, so no guess that could be counted.
		{"no header", "", 0},
		{"a wrong scheme", "Basic " + legacy, 0},
		{"a bearer scheme without a token", "Bearer ", 0},
		// A token that was tested and found wrong.
		{"a wrong shared token", "Bearer nope", 1},
		{"a malformed device token", "Bearer dm1.no-second-dot", 1},
		{"an unknown device", "Bearer " + noDevice, 1},
		{"a wrong secret for a known device", "Bearer dm1." + known.ID + "." + strings.Repeat("A", 43), 1},
		{"a removed device", "Bearer " + goneToken, 1},
	}
	for i, c := range cases {
		remote := fmt.Sprintf("198.51.100.%d:1000", i+1)
		before := len(f.failed)
		if rec := f.do(c.bearer, remote); rec.Code != http.StatusUnauthorized {
			t.Errorf("%s: code = %d, want 401", c.name, rec.Code)
		}
		// Counted or not, every one of them is reported.
		if got := f.failed[before:]; len(got) != 1 || got[0] != remote {
			t.Errorf("%s: failures reported = %q, want one from %s", c.name, got, remote)
		}
		if got := f.counted(remote); got != c.counted {
			t.Errorf("%s: %d failures counted, want %d", c.name, got, c.counted)
		}
	}
	if len(f.seen) != 0 {
		t.Fatalf("the handler ran for %d refused requests", len(f.seen))
	}
}

func TestRequestsWithoutATokenDoNotBlockTheAddress(t *testing.T) {
	f := newFixture(t, legacy)
	const remote = "203.0.113.7:40000"
	// Twice as many as wrong tokens it takes to block an address.
	const requests = 2 * throttle.Threshold
	for i := 0; i < requests; i++ {
		if rec := f.do("", remote); rec.Code != http.StatusUnauthorized {
			t.Fatalf("request %d without a token: code = %d, want 401", i+1, rec.Code)
		}
	}
	if len(f.failed) != requests {
		t.Fatalf("%d failures reported, want %d", len(f.failed), requests)
	}
	if rec := f.do("Bearer "+legacy, remote); rec.Code != http.StatusOK {
		t.Fatalf("the shared token from that address: code = %d, want 200", rec.Code)
	}
}

func TestASuccessIsNeverCounted(t *testing.T) {
	f := newFixture(t, legacy)
	_, token, _ := f.devices.Add("phone", state.RoleFull)
	for i, bearer := range []string{"Bearer " + token, "Bearer " + legacy} {
		remote := fmt.Sprintf("198.51.100.%d:1000", i+1)
		for n := 0; n < 3; n++ {
			if rec := f.do(bearer, remote); rec.Code != http.StatusOK {
				t.Fatalf("%s: code = %d, want 200", remote, rec.Code)
			}
		}
		if got := f.counted(remote); got != 0 {
			t.Errorf("%s: %d failures counted, want 0", remote, got)
		}
	}
	if len(f.failed) != 0 {
		t.Fatalf("%d failures reported, want 0", len(f.failed))
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
	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("the request did not start")
	}
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
	var told state.Device
	f.auth.OnCaller = func(_ *http.Request, d state.Device) { told = d }
	f.do("Bearer "+token, "")
	if told.ID != dev.ID {
		t.Fatalf("OnCaller got %q, want %q", told.ID, dev.ID)
	}
	if told.TokenHash != "" {
		t.Fatal("OnCaller got the hash of the token")
	}
}

// removingContext is a request context that runs remove the first time it is
// asked for Done. The registry asks while it tracks a request, which is after
// the token was accepted and before the request is registered.
type removingContext struct {
	context.Context
	once   sync.Once
	remove func()
}

func (c *removingContext) Done() <-chan struct{} {
	c.once.Do(c.remove)
	return c.Context.Done()
}

func TestADeviceRemovedBeforeItsRequestIsTrackedIsRefused(t *testing.T) {
	f := newFixture(t, "")
	dev, token, _ := f.devices.Add("phone", state.RoleFull)
	told := 0
	f.auth.OnCaller = func(*http.Request, state.Device) { told++ }
	removed := false
	ctx := &removingContext{Context: context.Background(), remove: func() {
		if _, ok, err := f.devices.Remove(dev.ID); !ok || err != nil {
			t.Errorf("remove: ok = %v, err = %v", ok, err)
		}
		f.auth.Conns.CloseDevice(dev.ID)
		removed = true
	}}
	const remote = "203.0.113.7:40000"
	ran := false
	h := f.auth.Require(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { ran = true }))
	req := httptest.NewRequest(http.MethodGet, "/events", nil).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+token)
	req.RemoteAddr = remote
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)

	if !removed {
		t.Fatal("the device was not removed while its request was tracked")
	}
	if rec.Code != http.StatusUnauthorized {
		t.Errorf("code = %d, want 401", rec.Code)
	}
	if ran {
		t.Error("the handler ran for a removed device")
	}
	if told != 0 {
		t.Error("OnCaller was told of a removed device")
	}
	if n := f.auth.Conns.Open(dev.ID); n != 0 {
		t.Errorf("open = %d, want 0", n)
	}
	// It is a failed credential like any other.
	if len(f.failed) != 1 || f.failed[0] != remote {
		t.Errorf("failures reported = %q, want one from %s", f.failed, remote)
	}
	if got := f.counted(remote); got != 1 {
		t.Errorf("%d failures counted, want 1", got)
	}
}

func TestADeviceRemovedAfterItsRequestIsTrackedHasItEnded(t *testing.T) {
	f := newFixture(t, "")
	_, token, _ := f.devices.Add("phone", state.RoleFull)
	// OnCaller runs when the device was found again after tracking, so this
	// removal lands behind that lookup and its close finds the request.
	f.auth.OnCaller = func(_ *http.Request, d state.Device) {
		if _, ok, err := f.devices.Remove(d.ID); !ok || err != nil {
			t.Errorf("remove: ok = %v, err = %v", ok, err)
		}
		if n := f.auth.Conns.CloseDevice(d.ID); n != 1 {
			t.Errorf("the close ended %d requests, want 1", n)
		}
	}
	ran := false
	var seen error
	h := f.auth.Require(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		ran, seen = true, r.Context().Err()
	}))
	req := httptest.NewRequest(http.MethodGet, "/events", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code == http.StatusServiceUnavailable {
		t.Error("code = 503 although the agent is not shutting down")
	}
	if !ran || seen != context.Canceled {
		t.Errorf("handler ran = %v with context error %v, want it run with an ended context", ran, seen)
	}
}

func TestAfterCloseAllARequestIsRefusedAsShuttingDown(t *testing.T) {
	f := newFixture(t, legacy)
	_, token, _ := f.devices.Add("phone", state.RoleFull)
	f.auth.Conns.CloseAll()
	for name, bearer := range map[string]string{
		"device":       "Bearer " + token,
		"shared token": "Bearer " + legacy,
	} {
		rec := f.do(bearer, "")
		if rec.Code != http.StatusServiceUnavailable {
			t.Errorf("%s: code = %d, want 503", name, rec.Code)
		}
		var body map[string]string
		if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body["message"] != "The agent is shutting down" {
			t.Errorf("%s: body = %q", name, rec.Body.String())
		}
	}
	if len(f.seen) != 0 {
		t.Errorf("the handler ran for %d requests after CloseAll", len(f.seen))
	}
	if len(f.failed) != 0 {
		t.Errorf("%d failures reported, want 0", len(f.failed))
	}
}

func TestAClientThatWentAwayIsNotAnsweredAsShuttingDown(t *testing.T) {
	f := newFixture(t, legacy)
	_, token, _ := f.devices.Add("phone", state.RoleFull)
	for name, bearer := range map[string]string{
		"device":       "Bearer " + token,
		"shared token": "Bearer " + legacy,
	} {
		gone, cancel := context.WithCancel(context.Background())
		cancel()
		ran := false
		h := f.auth.Require(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
			ran = r.Context().Err() == context.Canceled
		}))
		req := httptest.NewRequest(http.MethodGet, "/events", nil).WithContext(gone)
		req.Header.Set("Authorization", bearer)
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		if rec.Code == http.StatusServiceUnavailable {
			t.Errorf("%s: code = 503 although the agent is not shutting down", name)
		}
		if !ran {
			t.Errorf("%s: the handler did not run with the ended context", name)
		}
	}
}
