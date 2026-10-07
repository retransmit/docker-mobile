package admin

import (
	"bytes"
	"context"
	"crypto/rand"
	"errors"
	"log/slog"
	"net/http"
	"os"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/config"
	"github.com/retransmit/docker-mobile/agent/internal/conns"
	"github.com/retransmit/docker-mobile/agent/internal/pairing"
	"github.com/retransmit/docker-mobile/agent/internal/state"
)

// shortDir returns a state folder with a short path: a unix socket path may
// not exceed about a hundred bytes, and t.TempDir can be longer than that.
func shortDir(t *testing.T) *state.Dir {
	t.Helper()
	path, err := os.MkdirTemp("", "dma")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(path) })
	dir, err := state.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	return dir
}

type fixture struct {
	dir     *state.Dir
	server  *Server
	client  *Client
	devices *state.Devices
	pairing *pairing.Manager
	conns   *conns.Registry
	expire  chan time.Time
	log     *lockedBuffer
}

// lockedBuffer is a log sink the test can read while the server writes.
type lockedBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (l *lockedBuffer) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

func (l *lockedBuffer) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

var agentFP = bytes.Repeat([]byte{7}, 32)

// start serves the admin API on a socket in a fresh folder. configure runs
// before the server starts: its fields must not change afterwards.
func start(t *testing.T, configure ...func(*Server)) *fixture {
	t.Helper()
	dir := shortDir(t)
	devices, err := state.LoadDevices(dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	f := &fixture{
		dir:     dir,
		devices: devices,
		pairing: pairing.NewManager(time.Now, rand.Reader),
		conns:   conns.New(),
		expire:  make(chan time.Time),
		log:     &lockedBuffer{},
	}
	f.server = &Server{
		Pairing:            f.pairing,
		Devices:            devices,
		Conns:              f.conns,
		Advertise:          config.Advertise{Host: "my-server.lan", Port: "8443"},
		Fingerprint:        "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc",
		FingerprintDisplay: "SHA256:BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc",
		AgentName:          "home lab",
		Log:                slog.New(slog.NewTextHandler(f.log, nil)),
		After:              func(time.Duration) <-chan time.Time { return f.expire },
	}
	for _, c := range configure {
		c(f.server)
	}
	ln, err := Listen(dir)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	srv := &http.Server{Handler: f.server.Handler()}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	f.client = NewClient(dir.Path(""))
	return f
}

// pairAsync runs Pair in the background and returns its events and its error.
func (f *fixture) pairAsync(ctx context.Context, req PairRequest) (<-chan Event, <-chan error) {
	events := make(chan Event, 4)
	done := make(chan error, 1)
	go func() {
		done <- f.client.Pair(ctx, req, func(e Event) { events <- e })
	}()
	return events, done
}

func next(t *testing.T, events <-chan Event) Event {
	t.Helper()
	select {
	case e := <-events:
		return e
	case <-time.After(3 * time.Second):
		t.Fatal("no event arrived")
		return Event{}
	}
}

func finished(t *testing.T, done <-chan error) error {
	t.Helper()
	select {
	case err := <-done:
		return err
	case <-time.After(3 * time.Second):
		t.Fatal("Pair did not return")
		return nil
	}
}

// redeem plays the phone: it turns the code from a started event into a
// correct proof.
func (f *fixture) redeem(t *testing.T, formatted, name string) error {
	t.Helper()
	code, ok := pairing.Normalize(formatted)
	if !ok {
		t.Fatalf("the started event carries no valid code: %q", formatted)
	}
	nonce := bytes.Repeat([]byte{4}, pairing.NonceLen)
	_, err := f.pairing.Redeem(agentFP, nonce, pairing.PhoneProof(code, agentFP, nonce), name, f.devices.Add)
	return err
}

func TestPairStreamsTheCodeAndThenThePairedDevice(t *testing.T) {
	f := start(t)
	events, done := f.pairAsync(context.Background(), PairRequest{Role: "readonly"})
	started := next(t, events)
	if started.Event != EventStarted || started.Role != "readonly" {
		t.Fatalf("started = %+v", started)
	}
	if len(started.Code) != 14 || strings.Count(started.Code, "-") != 2 {
		t.Fatalf("code = %q, want XXXX-XXXX-XXXX", started.Code)
	}
	code, _ := pairing.Normalize(started.Code)
	wantLink := "dockermobile://pair?c=" + code + "&f=BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc&h=my-server.lan&n=home+lab&p=8443&v=1"
	if started.Link != wantLink {
		t.Fatalf("link =\n %s\nwant\n %s", started.Link, wantLink)
	}
	if started.Fingerprint != "SHA256:BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc" || started.Address != "my-server.lan:8443" {
		t.Fatalf("started = %+v", started)
	}
	if started.ExpiresIn < 295 || started.ExpiresIn > 300 {
		t.Fatalf("expiresIn = %d", started.ExpiresIn)
	}
	if err := f.redeem(t, started.Code, "Pixel 8"); err != nil {
		t.Fatalf("redeem: %v", err)
	}
	paired := next(t, events)
	if paired.Event != "paired" || paired.Device == nil || paired.Device.Name != "Pixel 8" || paired.Device.Role != "readonly" {
		t.Fatalf("paired = %+v", paired)
	}
	if err := finished(t, done); err != nil {
		t.Fatalf("Pair: %v", err)
	}
	log := f.log.String()
	if !strings.Contains(log, "pairing started") || !strings.Contains(log, "outcome=paired") {
		t.Fatalf("log = %s", log)
	}
	if strings.Contains(log, code) || strings.Contains(log, started.Code) {
		t.Fatal("the pairing code is in the log")
	}
}

func TestPairEndsAsExpiredWhenTheCodeRunsOut(t *testing.T) {
	f := start(t)
	events, done := f.pairAsync(context.Background(), PairRequest{})
	started := next(t, events)
	if started.Role != "full" {
		t.Fatalf("the default role = %q, want full", started.Role)
	}
	f.expire <- time.Now()
	if e := next(t, events); e.Event != "expired" {
		t.Fatalf("event = %+v", e)
	}
	if err := finished(t, done); err != nil {
		t.Fatalf("Pair: %v", err)
	}
	if err := f.redeem(t, started.Code, "x"); !errors.Is(err, pairing.ErrNone) {
		t.Fatalf("an expired code still pairs: %v", err)
	}
}

func TestLeavingThePairCommandCancelsTheCode(t *testing.T) {
	f := start(t)
	ctx, cancel := context.WithCancel(context.Background())
	events, done := f.pairAsync(ctx, PairRequest{})
	started := next(t, events)
	cancel()
	if err := finished(t, done); !errors.Is(err, context.Canceled) {
		t.Fatalf("Pair err = %v, want context.Canceled", err)
	}
	// The agent notices the closed connection a moment later.
	deadline := time.Now().Add(3 * time.Second)
	for !strings.Contains(f.log.String(), "outcome=cancelled") {
		if time.Now().After(deadline) {
			t.Fatal("the agent did not cancel the pairing")
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err := f.redeem(t, started.Code, "x"); !errors.Is(err, pairing.ErrNone) {
		t.Fatalf("the code is still usable after the command left: %v", err)
	}
	if len(f.devices.List()) != 0 {
		t.Fatal("a device was created with a cancelled code")
	}
}

func TestASecondPairReplacesTheFirst(t *testing.T) {
	f := start(t)
	firstEvents, firstDone := f.pairAsync(context.Background(), PairRequest{})
	next(t, firstEvents)
	secondEvents, _ := f.pairAsync(context.Background(), PairRequest{})
	next(t, secondEvents)
	if e := next(t, firstEvents); e.Event != "replaced" {
		t.Fatalf("event = %+v", e)
	}
	if err := finished(t, firstDone); err != nil {
		t.Fatalf("Pair: %v", err)
	}
}

func TestPairRequestOptions(t *testing.T) {
	f := start(t)
	events, _ := f.pairAsync(context.Background(), PairRequest{Host: "10.0.0.5:9000", Name: "kitchen"})
	started := next(t, events)
	if started.Address != "10.0.0.5:9000" || !strings.Contains(started.Link, "h=10.0.0.5&") || !strings.Contains(started.Link, "p=9000") {
		t.Fatalf("started = %+v", started)
	}
	if err := f.redeem(t, started.Code, "what the phone calls itself"); err != nil {
		t.Fatal(err)
	}
	if e := next(t, events); e.Device == nil || e.Device.Name != "kitchen" {
		t.Fatalf("the name given on the command line did not win: %+v", e)
	}

	for name, req := range map[string]PairRequest{
		"unknown role": {Role: "admin"},
		"bad host":     {Host: "https://x"},
	} {
		err := f.client.Pair(context.Background(), req, func(Event) { t.Errorf("%s: an event arrived", name) })
		if err == nil {
			t.Errorf("%s was accepted", name)
		}
	}
}

func TestPairWithoutAnAdvertisedAddressLeavesItOut(t *testing.T) {
	f := start(t, func(s *Server) { s.Advertise = config.Advertise{Port: "8443"} })
	events, _ := f.pairAsync(context.Background(), PairRequest{})
	started := next(t, events)
	if started.Address != "" || strings.Contains(started.Link, "h=") || strings.Contains(started.Link, "p=") {
		t.Fatalf("started = %+v", started)
	}
}

func TestPairBehindAProxyCarriesASchemeInsteadOfAFingerprint(t *testing.T) {
	f := start(t, func(s *Server) {
		s.Advertise = config.Advertise{Scheme: "https", Host: "docker.example.com", Port: "443"}
		s.Fingerprint, s.FingerprintDisplay = "", ""
	})
	events, _ := f.pairAsync(context.Background(), PairRequest{})
	started := next(t, events)
	if started.Fingerprint != "" || started.Address != "https://docker.example.com:443" {
		t.Fatalf("started = %+v", started)
	}
	if !strings.Contains(started.Link, "s=https") || strings.Contains(started.Link, "f=") {
		t.Fatalf("link = %s", started.Link)
	}
}

func TestDevicesListsWithoutTokenHashes(t *testing.T) {
	f := start(t)
	a, _, _ := f.devices.Add("a", state.RoleFull)
	time.Sleep(2 * time.Millisecond)
	b, _, _ := f.devices.Add("b", state.RoleReadOnly)
	list, err := f.client.Devices(context.Background())
	if err != nil {
		t.Fatalf("Devices: %v", err)
	}
	if len(list) != 2 || list[0].ID != a.ID || list[1].ID != b.ID || list[1].Role != "readonly" {
		t.Fatalf("list = %+v", list)
	}
	resp, err := f.client.do(context.Background(), http.MethodGet, "/devices", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var raw bytes.Buffer
	raw.ReadFrom(resp.Body)
	if strings.Contains(strings.ToLower(raw.String()), "hash") || strings.Contains(raw.String(), a.TokenHash) {
		t.Fatalf("the answer carries a token hash: %s", raw.String())
	}
}

func TestRevokeRemovesTheDeviceAndClosesItsRequests(t *testing.T) {
	f := start(t)
	dev, token, _ := f.devices.Add("phone", state.RoleFull)
	ctx, release := f.conns.Track(context.Background(), dev.ID)
	defer release()

	got, closed, err := f.client.Revoke(context.Background(), dev.ID)
	if err != nil {
		t.Fatalf("Revoke: %v", err)
	}
	if got.ID != dev.ID || closed != 1 {
		t.Fatalf("revoked = %+v, closed = %d", got, closed)
	}
	select {
	case <-ctx.Done():
	default:
		t.Fatal("the open request of the revoked device was not closed")
	}
	if _, ok := f.devices.Authenticate(token); ok {
		t.Fatal("the revoked token still authenticates")
	}
	if _, _, err := f.client.Revoke(context.Background(), dev.ID); err == nil || !strings.Contains(err.Error(), "no device") {
		t.Fatalf("revoking twice: err = %v", err)
	}
	if _, _, err := f.client.Revoke(context.Background(), "../devices"); err == nil {
		t.Fatal("an id with a path in it was accepted")
	}
}

func TestWithoutARunningAgentTheClientSaysSo(t *testing.T) {
	c := NewClient(shortDir(t).Path(""))
	if _, err := c.Devices(context.Background()); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("err = %v, want ErrNotRunning", err)
	}
	if err := c.Pair(context.Background(), PairRequest{}, func(Event) {}); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("Pair err = %v, want ErrNotRunning", err)
	}
}

func TestListenRefusesASecondAgentAndReplacesAStaleSocket(t *testing.T) {
	dir := shortDir(t)
	first, err := Listen(dir)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	go http.Serve(first, http.NotFoundHandler())
	if _, err := Listen(dir); err == nil || !strings.Contains(err.Error(), "already running") {
		t.Fatalf("a second agent on the same folder: err = %v", err)
	}
	first.Close()

	// A socket file nobody listens on is stale and gets replaced.
	if err := os.WriteFile(dir.Path(socketName), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	second, err := Listen(dir)
	if err != nil {
		t.Fatalf("Listen over a stale socket: %v", err)
	}
	defer second.Close()
	if runtime.GOOS != "windows" {
		info, err := os.Stat(dir.Path(socketName))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("socket mode = %v, want 0600", info.Mode().Perm())
		}
	}
}
