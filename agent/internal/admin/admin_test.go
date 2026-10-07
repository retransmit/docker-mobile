package admin

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"errors"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
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

	mu    sync.Mutex
	armed []time.Duration // what the expiry timer was armed with, in order
}

// timers returns what the server has armed its expiry timer with so far.
func (f *fixture) timers() []time.Duration {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]time.Duration(nil), f.armed...)
}

// steppingClock moves on by a second every time it is read, so that two
// things made one after the other never carry the same time, however coarse
// the clock of the machine is.
type steppingClock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *steppingClock) Now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(time.Second)
	return c.t
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
	return startAt(t, time.Now, configure...)
}

// startAt is start with the clock the device list reads.
func startAt(t *testing.T, now func() time.Time, configure ...func(*Server)) *fixture {
	t.Helper()
	dir := shortDir(t)
	devices, err := state.LoadDevices(dir, now)
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
		After: func(d time.Duration) <-chan time.Time {
			f.mu.Lock()
			f.armed = append(f.armed, d)
			f.mu.Unlock()
			return f.expire
		},
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
	// The handler takes this only once it waits, so its timer is armed by now.
	f.expire <- time.Now()
	if armed := f.timers(); len(armed) != 1 || armed[0] > pairing.Lifetime || armed[0] < pairing.Lifetime-5*time.Second {
		t.Fatalf("the expiry timer was armed with %v, want once, with what is left of the %v a code lives", armed, pairing.Lifetime)
	}
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

func TestPairReportsAnOutcomeItHasHandedOnWhateverBecomesOfTheContext(t *testing.T) {
	// An agent that sends the outcome and then keeps the stream open. The
	// command line is interrupted with the outcome in hand: that is the
	// moment a phone completes the pairing and its owner presses Ctrl-C.
	dir := shortDir(t)
	ln, err := Listen(dir)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		enc := json.NewEncoder(w)
		enc.Encode(Event{Event: EventStarted})
		enc.Encode(Event{Event: "paired", Device: &DeviceInfo{ID: "0a1b2c3d", Name: "Pixel 8", Role: "full"}})
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	var got []string
	done := make(chan error, 1)
	go func() {
		done <- NewClient(dir.Path("")).Pair(ctx, PairRequest{}, func(e Event) {
			got = append(got, e.Event)
			if e.Event == "paired" {
				cancel()
			}
		})
	}()
	if err := finished(t, done); err != nil {
		t.Fatalf("Pair returned %v although it had handed on how the pairing ended", err)
	}
	if len(got) != 2 || got[0] != EventStarted || got[1] != "paired" {
		t.Fatalf("events = %v, want started and paired", got)
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
	// The list is ordered by when a device was paired, so the two get times
	// that differ whatever the clock of the machine does.
	clock := &steppingClock{t: time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)}
	f := startAt(t, clock.Now)
	a, _, _ := f.devices.Add("a", state.RoleFull)
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

func TestRevokeSaysTheDeviceIsStillPairedWhenTheRemovalCannotBeStored(t *testing.T) {
	// The device list lives in a folder of its own here, apart from the
	// socket and the lock, so that the folder can go while the server runs.
	store := shortDir(t)
	devices, err := state.LoadDevices(store, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	f := start(t, func(s *Server) { s.Devices = devices })
	dev, token, err := devices.Add("phone", state.RoleFull)
	if err != nil {
		t.Fatal(err)
	}
	open, release := f.conns.Track(context.Background(), dev.ID)
	defer release()
	// Nothing can be written from here on.
	if err := os.RemoveAll(store.Path("")); err != nil {
		t.Fatal(err)
	}

	_, _, err = f.client.Revoke(context.Background(), dev.ID)
	if err == nil {
		t.Fatal("Revoke reported success although the removal could not be stored")
	}
	if !strings.HasPrefix(err.Error(), "the device is still paired") {
		t.Errorf("the error does not begin by saying that the device is still paired: %v", err)
	}
	for _, want := range []string{"the removal could not be stored", "write devices.json"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the error does not say %q: %v", want, err)
		}
	}
	// And so it is: the device works as before and its request is open.
	if _, ok := devices.Authenticate(token); !ok {
		t.Fatal("the device no longer authenticates")
	}
	if list := devices.List(); len(list) != 1 || list[0].ID != dev.ID {
		t.Fatalf("the list holds %d devices, want the one whose removal failed", len(list))
	}
	select {
	case <-open.Done():
		t.Fatal("the open request of the device was closed")
	default:
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

	// A state folder that was never created.
	missing := filepath.Join(shortDir(t).Path(""), "missing")
	if _, err := NewClient(missing).Devices(context.Background()); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("without the folder: err = %v, want ErrNotRunning", err)
	}

	// A socket that an agent left behind when it died: nobody listens on it.
	dir := shortDir(t)
	dead, err := net.Listen("unix", dir.Path(socketName))
	if err != nil {
		t.Fatal(err)
	}
	dead.(*net.UnixListener).SetUnlinkOnClose(false)
	dead.Close()
	if _, err := NewClient(dir.Path("")).Devices(context.Background()); !errors.Is(err, ErrNotRunning) {
		t.Fatalf("with a socket nobody listens on: err = %v, want ErrNotRunning", err)
	}
}

func TestTheClientSaysWhyItCouldNotReachTheAgent(t *testing.T) {
	// A file stands in for the socket, so that the cause of the failed
	// connection is all that differs between the cases.
	path := shortDir(t).Path(socketName)
	if err := os.WriteFile(path, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	failed := func(cause syscall.Errno) error {
		return dialFailure(path, &net.OpError{Op: "dial", Net: "unix", Err: os.NewSyscallError("connect", cause)})
	}

	denied := failed(syscall.EACCES)
	if !errors.Is(denied, ErrNoAccess) || errors.Is(denied, ErrNotRunning) {
		t.Fatalf("permission denied: err = %v, want ErrNoAccess", denied)
	}
	if !strings.Contains(denied.Error(), "the user the agent runs as") {
		t.Fatalf("permission denied: the error does not say what to do: %v", denied)
	}

	other := failed(syscall.EMFILE)
	if errors.Is(other, ErrNotRunning) || errors.Is(other, ErrNoAccess) {
		t.Fatalf("another failure was taken for one of the known ones: %v", other)
	}
	if !strings.Contains(other.Error(), syscall.EMFILE.Error()) {
		t.Fatalf("another failure lost its cause: %v", other)
	}
}

func TestTheClientSaysWhenTheStateFolderBelongsToAnotherUser(t *testing.T) {
	if runtime.GOOS == "windows" || os.Geteuid() == 0 {
		t.Skip("needs file modes, and a user they hold for")
	}
	f := start(t)
	// What a user other than the agent's finds: a folder that may not be
	// entered, with a running agent behind it.
	folder := f.dir.Path("")
	if err := os.Chmod(folder, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Chmod(folder, 0o700) })
	_, err := f.client.Devices(context.Background())
	if !errors.Is(err, ErrNoAccess) || errors.Is(err, ErrNotRunning) {
		t.Fatalf("Devices err = %v, want ErrNoAccess", err)
	}
	err = f.client.Pair(context.Background(), PairRequest{}, func(Event) {})
	if !errors.Is(err, ErrNoAccess) {
		t.Fatalf("Pair err = %v, want ErrNoAccess", err)
	}
}

func TestAStateFolderPathTooLongForTheSocketIsAClearError(t *testing.T) {
	if err := checkSocketPath(strings.Repeat("x", maxSocketPath)); err != nil {
		t.Fatalf("a socket path of exactly %d bytes: %v", maxSocketPath, err)
	}
	if err := checkSocketPath(strings.Repeat("x", maxSocketPath+1)); err == nil {
		t.Fatalf("a socket path of %d bytes was accepted", maxSocketPath+1)
	}

	dir, err := state.Open(filepath.Join(shortDir(t).Path(""), strings.Repeat("x", 100)))
	if err != nil {
		t.Fatal(err)
	}
	length := strconv.Itoa(len(dir.Path(socketName)))
	check := func(what string, err error) {
		t.Helper()
		if err == nil {
			t.Errorf("%s: no error for a socket path of %s bytes", what, length)
			return
		}
		for _, want := range []string{"too long", length, strconv.Itoa(maxSocketPath)} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("%s: the error does not say %q: %v", what, want, err)
			}
		}
		if errors.Is(err, ErrNotRunning) {
			t.Errorf("%s: a path that is too long was reported as no agent running: %v", what, err)
		}
	}
	ln, err := Listen(dir)
	if err == nil {
		ln.Close()
	}
	check("Listen", err)
	if _, err := os.Stat(dir.Path(lockName)); !errors.Is(err, fs.ErrNotExist) {
		t.Errorf("Listen took the folder before it refused the path: %v", err)
	}
	_, err = NewClient(dir.Path("")).Devices(context.Background())
	check("Devices", err)
	check("Pair", NewClient(dir.Path("")).Pair(context.Background(), PairRequest{}, func(Event) {}))
}

func TestAStateFolderPathOfTheLongestLengthWorks(t *testing.T) {
	base := shortDir(t).Path("")
	// base, a separator, the folder, a separator and the socket's name.
	pad := maxSocketPath - len(base) - len(socketName) - 2
	if pad < 1 {
		t.Skipf("the temporary folder %s is too long to build a path of %d bytes in", base, maxSocketPath)
	}
	dir, err := state.Open(filepath.Join(base, strings.Repeat("x", pad)))
	if err != nil {
		t.Fatal(err)
	}
	if n := len(dir.Path(socketName)); n != maxSocketPath {
		t.Fatalf("the socket path is %d bytes, want %d", n, maxSocketPath)
	}
	ln, err := Listen(dir)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	serve(t, ln)
	if err := ask(dir); err != nil {
		t.Fatalf("the agent does not answer: %v", err)
	}
}

// serve answers every request on ln until the test ends.
func serve(t *testing.T, ln net.Listener) {
	t.Helper()
	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusNoContent)
	})}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
}

// ask sends one request to whoever serves the admin socket of dir.
func ask(dir *state.Dir) error {
	c := NewClient(dir.Path(""))
	defer c.http.CloseIdleConnections()
	resp, err := c.do(context.Background(), http.MethodGet, "/", nil)
	if err != nil {
		return err
	}
	return resp.Body.Close()
}

// refused reports whether Listen turned a second agent away. A listener that
// was handed out after all is closed, so that it cannot hold the folder.
func refused(ln net.Listener, err error) bool {
	if err == nil {
		ln.Close()
		return false
	}
	return strings.Contains(err.Error(), "already running")
}

func TestListenRefusesASecondAgentAndReplacesAStaleSocket(t *testing.T) {
	dir := shortDir(t)
	first, err := Listen(dir)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	serve(t, first)
	if err := ask(dir); err != nil {
		t.Fatalf("the first agent does not answer: %v", err)
	}
	if ln, err := Listen(dir); !refused(ln, err) {
		t.Fatalf("a second agent on the same folder: err = %v", err)
	}
	if err := ask(dir); err != nil {
		t.Fatalf("the first agent stopped answering once a second one was refused: %v", err)
	}
	// The folder stays taken when the socket file is gone: what refuses a
	// second agent is not whether a socket can be found and reached.
	if err := os.Remove(dir.Path(socketName)); err != nil {
		t.Fatal(err)
	}
	if ln, err := Listen(dir); !refused(ln, err) {
		t.Fatalf("a second agent after the socket file was removed: err = %v", err)
	}

	// An agent that died leaves its socket behind and holds nothing: the
	// file is replaced.
	dir = shortDir(t)
	dead, err := net.Listen("unix", dir.Path(socketName))
	if err != nil {
		t.Fatal(err)
	}
	dead.(*net.UnixListener).SetUnlinkOnClose(false)
	dead.Close()
	if _, err := os.Stat(dir.Path(socketName)); err != nil {
		t.Fatalf("the left-over socket is not there: %v", err)
	}
	second, err := Listen(dir)
	if err != nil {
		t.Fatalf("Listen over a left-over socket: %v", err)
	}
	serve(t, second)
	if err := ask(dir); err != nil {
		t.Fatalf("the agent does not answer on the socket it replaced: %v", err)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(dir.Path(socketName))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("socket mode = %v, want 0600", info.Mode().Perm())
		}
		info, err = os.Stat(dir.Path(lockName))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("lock file mode = %v, want 0600", info.Mode().Perm())
		}
	}
}

func TestClosingTheListenerFreesTheStateFolder(t *testing.T) {
	dir := shortDir(t)
	first, err := Listen(dir)
	if err != nil {
		t.Fatalf("Listen: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := first.Close(); err != nil {
		t.Fatalf("closing a second time: %v", err)
	}
	if _, err := os.Stat(dir.Path(socketName)); !errors.Is(err, fs.ErrNotExist) {
		t.Fatalf("the socket is still there after Close: %v", err)
	}
	second, err := Listen(dir)
	if err != nil {
		t.Fatalf("Listen after the first listener was closed: %v", err)
	}
	serve(t, second)
	if err := ask(dir); err != nil {
		t.Fatalf("the second agent does not answer: %v", err)
	}
}

func TestAFailedListenDoesNotKeepTheStateFolder(t *testing.T) {
	dir := shortDir(t)
	// Something that cannot be removed the way a file can sits where the
	// socket goes.
	inTheWay := dir.Path(socketName)
	if err := os.Mkdir(inTheWay, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(inTheWay, "x"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	if ln, err := Listen(dir); err == nil {
		ln.Close()
		t.Fatal("Listen succeeded with a folder where the socket goes")
	} else if strings.Contains(err.Error(), "already running") {
		t.Fatalf("err = %v, want what is in the way", err)
	}
	if err := os.RemoveAll(inTheWay); err != nil {
		t.Fatal(err)
	}
	ln, err := Listen(dir)
	if err != nil {
		t.Fatalf("Listen after one that failed: %v", err)
	}
	ln.Close()
}

func TestOfAgentsStartedTogetherOnlyOneGetsTheStateFolder(t *testing.T) {
	const rounds, agents = 5, 8
	for round := 0; round < rounds; round++ {
		dir := shortDir(t)
		var (
			wg  sync.WaitGroup
			mu  sync.Mutex
			won []net.Listener
		)
		begin := make(chan struct{})
		for i := 0; i < agents; i++ {
			wg.Add(1)
			go func() {
				defer wg.Done()
				<-begin
				ln, err := Listen(dir)
				if err != nil {
					if !strings.Contains(err.Error(), "already running") {
						t.Errorf("round %d: an agent was turned away with %v", round, err)
					}
					return
				}
				mu.Lock()
				won = append(won, ln)
				mu.Unlock()
			}()
		}
		close(begin)
		wg.Wait()
		if len(won) != 1 {
			t.Errorf("round %d: %d agents got the folder, want 1", round, len(won))
		}
		for _, ln := range won {
			ln.Close()
		}
	}
}

// departing is the context of a request whose client leaves at a moment the
// test picks. Done hands out a channel that is never closed: leave sends on
// it, and the send returns only when the handler has taken it. So the test
// knows, without waiting on a clock, that the handler has seen the client go
// and is past choosing what to do about it.
type departing struct {
	context.Context
	cancel context.CancelFunc
	gone   chan struct{}
}

func newDeparting() *departing {
	ctx, cancel := context.WithCancel(context.Background())
	return &departing{Context: ctx, cancel: cancel, gone: make(chan struct{})}
}

func (d *departing) Done() <-chan struct{} { return d.gone }

func (d *departing) leave(t *testing.T) {
	t.Helper()
	d.cancel()
	select {
	case d.gone <- struct{}{}:
	case <-time.After(3 * time.Second):
		t.Fatal("the handler did not notice that the command line left")
	}
}

// lineWriter is a response the test reads line by line while the handler is
// still running.
type lineWriter struct {
	header http.Header
	lines  chan []byte
}

func (w *lineWriter) Header() http.Header { return w.header }
func (w *lineWriter) WriteHeader(int)     {}
func (w *lineWriter) Write(p []byte) (int, error) {
	w.lines <- bytes.Clone(p)
	return len(p), nil
}

func TestTheLogSaysPairedWhenTheCommandLeavesWhileThePhoneRedeems(t *testing.T) {
	f := start(t)
	ctx := newDeparting()
	w := &lineWriter{header: http.Header{}, lines: make(chan []byte, 4)}
	req := httptest.NewRequest(http.MethodPost, "/pair", strings.NewReader("{}")).WithContext(ctx)
	returned := make(chan struct{})
	go func() {
		defer close(returned)
		f.server.handlePair(w, req)
	}()
	var started Event
	select {
	case line := <-w.lines:
		if err := json.Unmarshal(line, &started); err != nil {
			t.Fatalf("the first line is not an event: %v", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("no event arrived")
	}
	code, ok := pairing.Normalize(started.Code)
	if !ok {
		t.Fatalf("the started event carries no valid code: %q", started.Code)
	}

	// The phone's proof is right and its device is about to be stored: from
	// here until release is closed the redeem is under way.
	storing, release := make(chan struct{}), make(chan struct{})
	type outcome struct {
		device state.Device
		err    error
	}
	redeemed := make(chan outcome, 1)
	go func() {
		nonce := bytes.Repeat([]byte{4}, pairing.NonceLen)
		got, err := f.pairing.Redeem(agentFP, nonce, pairing.PhoneProof(code, agentFP, nonce), "Pixel 8",
			func(name string, role state.Role) (state.Device, string, error) {
				close(storing)
				<-release
				return f.devices.Add(name, role)
			})
		redeemed <- outcome{got.Device, err}
	}()
	select {
	case <-storing:
	case <-time.After(3 * time.Second):
		t.Fatal("the redeem did not get as far as storing the device")
	}

	// Now the command line goes away, and only then does the redeem finish.
	ctx.leave(t)
	close(release)

	var got outcome
	select {
	case got = <-redeemed:
	case <-time.After(3 * time.Second):
		t.Fatal("the redeem did not return")
	}
	if got.err != nil {
		t.Fatalf("redeem: %v", got.err)
	}
	select {
	case <-returned:
	case <-time.After(3 * time.Second):
		t.Fatal("the handler did not return")
	}
	if list := f.devices.List(); len(list) != 1 || list[0].ID != got.device.ID {
		t.Fatalf("devices = %+v, want the one that was paired", list)
	}
	log := f.log.String()
	if strings.Contains(log, "outcome=cancelled") {
		t.Fatalf("the log calls a pairing that stored a device cancelled:\n%s", log)
	}
	if !strings.Contains(log, "outcome=paired") || !strings.Contains(log, "device="+got.device.ID) || !strings.Contains(log, `name="Pixel 8"`) {
		t.Fatalf("the log does not say which device was paired:\n%s", log)
	}
	if strings.Contains(log, code) || strings.Contains(log, started.Code) {
		t.Fatal("the pairing code is in the log")
	}
}
