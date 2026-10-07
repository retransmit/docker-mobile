package main

import (
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/gorilla/websocket"
	"github.com/retransmit/docker-mobile/agent/internal/admin"
	"github.com/retransmit/docker-mobile/agent/internal/config"
	"github.com/retransmit/docker-mobile/agent/internal/tlsid"
)

func TestMain(m *testing.M) {
	// Streams never end by themselves, so every test that stops an agent
	// with one open would wait the whole grace.
	shutdownGrace = 200 * time.Millisecond
	os.Exit(m.Run())
}

// syncBuf is a buffer a command can write to while the test reads it.
type syncBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuf) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.Write(p)
}

func (s *syncBuf) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.b.String()
}

func waitFor(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for !ok() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// terminalGreeting is what the fake daemon sends once a terminal is open.
const terminalGreeting = "ready"

// fakeDocker answers lists at once and keeps /events open until the caller
// goes away. It starts a terminal the way the daemon does: for POST
// /exec/<id>/start it takes the connection over, answers 101, sends
// terminalGreeting and then holds the connection until the caller closes it.
func fakeDocker(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/exec/") && strings.HasSuffix(r.URL.Path, "/start") {
			io.Copy(io.Discard, r.Body)
			conn, rw, err := w.(http.Hijacker).Hijack()
			if err != nil {
				return
			}
			defer conn.Close()
			rw.WriteString("HTTP/1.1 101 UPGRADED\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n" + terminalGreeting)
			rw.Flush()
			io.Copy(io.Discard, rw)
			return
		}
		if strings.HasSuffix(r.URL.Path, "/events") {
			w.Header().Set("Content-Type", "application/json")
			w.Write([]byte("{\"Type\":\"container\"}\n"))
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"Id":"x"}]`))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// agent is a running agent under test.
type agent struct {
	t      *testing.T
	env    map[string]string
	addr   string
	log    *syncBuf
	cancel context.CancelFunc
	done   chan error
}

func (a *agent) getenv(k string) string { return a.env[k] }

// startAgent runs serve in the background on a free port with a fresh state
// folder. extra is more environment, as key, value pairs.
func startAgent(t *testing.T, extra ...string) *agent {
	t.Helper()
	// A short path: the admin socket lives in it, and a unix socket path
	// may not exceed about a hundred bytes.
	dataDir, err := os.MkdirTemp("", "dma")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dataDir) })
	// The fake daemon takes its port before the agent's is looked for:
	// started after the probe, it would be the nearest contender for the
	// port the probe has just given back.
	docker := fakeDocker(t)

	a := &agent{t: t, log: &syncBuf{}, env: map[string]string{
		"AGENT_DATA":      dataDir,
		"AGENT_ADVERTISE": "127.0.0.1",
		"AGENT_NAME":      "test agent",
		"DOCKER_HOST":     "tcp://" + docker.Listener.Addr().String(),
	}}
	for i := 0; i+1 < len(extra); i += 2 {
		a.env[extra[i]] = extra[i+1]
	}
	// An address the caller names is the one to use, and no other.
	_, named := a.env["AGENT_LISTEN"]
	for try := 1; ; try++ {
		if !named {
			a.env["AGENT_LISTEN"] = freeAddress(t)
		}
		cfg, err := config.Load(a.getenv, false)
		if err != nil {
			t.Fatalf("config: %v", err)
		}
		ctx, cancel := context.WithCancel(context.Background())
		// Whatever happens below, the agent is told to stop when the test
		// is over: one that never reported ready would otherwise keep its
		// port, its folder and its goroutine.
		t.Cleanup(cancel)
		ready, done := make(chan net.Addr, 1), make(chan error, 1)
		a.cancel, a.done = cancel, done
		go func() {
			done <- serve(ctx, cfg, slog.New(slog.NewTextHandler(a.log, nil)), func(addr net.Addr) { ready <- addr })
		}()
		select {
		case addr := <-ready:
			a.addr = addr.String()
			t.Cleanup(func() { a.stop() })
			return a
		case err := <-done:
			// A port that was free when it was looked for can be someone
			// else's by the time the agent asks for it. Then another one is
			// looked for, a few times at most. Whatever else ends the agent
			// at once is a failure.
			if named || try == startTries || !addressInUse(err) {
				t.Fatalf("serve ended at once: %v", err)
			}
		case <-time.After(5 * time.Second):
			t.Fatal("the agent did not start")
		}
	}
}

// startTries is how often startAgent looks for a port before it gives up.
const startTries = 5

// freeAddress returns an address on this machine that nothing listens on at
// this moment. It is not kept: whoever wants it has to take it, and may find
// it taken.
func freeAddress(t *testing.T) string {
	t.Helper()
	probe, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer probe.Close()
	return probe.Addr().String()
}

// addressInUse reports whether err says that the address to listen on is
// taken. Windows has a number of its own for that.
func addressInUse(err error) bool {
	const windowsAddressInUse = syscall.Errno(10048) // WSAEADDRINUSE
	return errors.Is(err, syscall.EADDRINUSE) || errors.Is(err, windowsAddressInUse)
}

// stop ends the agent and returns what serve returned. It may be called
// more than once.
func (a *agent) stop() error {
	a.cancel()
	select {
	case err := <-a.done:
		a.done <- err
		return err
	case <-time.After(5 * time.Second):
		a.t.Fatal("the agent did not stop")
		return nil
	}
}

// command runs one command line against this agent's environment.
func (a *agent) command(args ...string) (code int, stdout, stderr string) {
	var out, errOut syncBuf
	code = run(context.Background(), args, a.getenv, &out, &errOut)
	return code, out.String(), errOut.String()
}

// fingerprint is what the agent's state folder says its identity is.
func (a *agent) fingerprint() tlsid.Fingerprint {
	a.t.Helper()
	fp, err := tlsid.ReadFingerprint(a.env["AGENT_DATA"])
	if err != nil {
		a.t.Fatalf("read the fingerprint: %v", err)
	}
	return fp
}

// phone plays the app: it pins a fingerprint the way the app does and
// carries a token.
type phone struct {
	t      *testing.T
	scheme string
	addr   string
	token  string
	client *http.Client

	// mu guards pin and seen. A handshake reads and writes them on a
	// goroutine of the transport, and that goroutine can still be running
	// when the request it was started for has returned: a request that ends
	// with its context leaves its dial behind. Nothing touches the two
	// fields but the four methods below.
	mu sync.Mutex
	// pin is the key the phone holds its connections to. It is nil until the
	// phone trusts a certificate. For the length of a pairing attempt it is
	// what the first connection of that attempt presented, and it stays
	// after the attempt only if the phone was paired.
	pin *tlsid.Fingerprint
	// seen is what the last handshake presented.
	seen tlsid.Fingerprint
}

// present records what a handshake presented and reports whether the phone
// takes it: any key while it holds its connections to none, and after that
// the pinned key and no other.
func (p *phone) present(fp tlsid.Fingerprint) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.seen = fp
	return p.pin == nil || fp == *p.pin
}

// presented returns what the last handshake presented.
func (p *phone) presented() tlsid.Fingerprint {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.seen
}

// trusted returns the key the phone holds its connections to, nil when it
// holds them to none. What it points to is never written again.
func (p *phone) trusted() *tlsid.Fingerprint {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.pin
}

// trust makes pin the key the phone holds its connections to; nil lifts
// that. The caller must not write to what pin points to afterwards.
func (p *phone) trust(pin *tlsid.Fingerprint) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.pin = pin
}

func newPhone(t *testing.T, scheme, addr string) *phone {
	p := &phone{t: t, scheme: scheme, addr: addr}
	p.client = &http.Client{Transport: &http.Transport{
		DisableKeepAlives: true,
		TLSClientConfig: &tls.Config{
			// The agent's certificate is self-signed, so the chain check
			// cannot pass. Like the app, the phone replaces it with a
			// stricter one: the key must be exactly the pinned one.
			InsecureSkipVerify: true,
			VerifyPeerCertificate: func(raw [][]byte, _ [][]*x509.Certificate) error {
				fp, err := tlsid.FingerprintOfDER(raw[0])
				if err != nil {
					return err
				}
				if !p.present(fp) {
					return errors.New("server identity changed")
				}
				return nil
			},
		},
	}}
	return p
}

// pinned returns a phone that already trusts this agent's certificate.
func (a *agent) pinned(token string) *phone {
	p := newPhone(a.t, "https", a.addr)
	fp := a.fingerprint()
	p.trust(&fp)
	p.token = token
	return p
}

func (p *phone) do(method, path string, body []byte) (*http.Response, error) {
	return p.doWithin(context.Background(), method, path, body)
}

// doWithin is do for a request that ends with ctx, the reading of its answer
// included.
func (p *phone) doWithin(ctx context.Context, method, path string, body []byte) (*http.Response, error) {
	req, err := p.request(ctx, method, path, body)
	if err != nil {
		return nil, err
	}
	return p.client.Do(req)
}

// request builds a request of the phone, with its token when it has one.
func (p *phone) request(ctx context.Context, method, path string, body []byte) (*http.Request, error) {
	req, err := http.NewRequestWithContext(ctx, method, p.scheme+"://"+p.addr+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	if p.token != "" {
		req.Header.Set("Authorization", "Bearer "+p.token)
	}
	return req, nil
}

func (p *phone) status(method, path string) int {
	p.t.Helper()
	resp, err := p.do(method, path, nil)
	if err != nil {
		p.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	io.Copy(io.Discard, resp.Body)
	return resp.StatusCode
}

const shared = "a-shared-token-of-enough-length"

func TestTheSharedTokenWorksOverThePinnedCertificate(t *testing.T) {
	a := startAgent(t, "AGENT_TOKEN", shared)
	log := a.log.String()
	if !strings.Contains(log, "AGENT_TOKEN is set") || !strings.Contains(log, "AGENT_TOKEN is short") {
		t.Fatalf("the log lacks the notice or the warning about the shared token: %s", log)
	}
	if strings.Contains(log, shared) {
		t.Fatal("the shared token is in the log")
	}
	if strings.Contains(log, "length=") {
		t.Fatalf("the length of the shared token is in the log: %s", log)
	}
	p := a.pinned(shared)
	if got := p.status("GET", "/v1.45/containers/json"); got != http.StatusOK {
		t.Fatalf("code = %d, want 200", got)
	}
	p.token = "wrong"
	if got := p.status("GET", "/containers/json"); got != http.StatusUnauthorized {
		t.Fatalf("code = %d, want 401", got)
	}
}

func TestASharedTokenOf32CharactersStartsWithoutTheWarning(t *testing.T) {
	a := startAgent(t, "AGENT_TOKEN", strings.Repeat("s", 32))
	log := a.log.String()
	if !strings.Contains(log, "AGENT_TOKEN is set") {
		t.Fatalf("the log lacks the notice about the shared token: %s", log)
	}
	if strings.Contains(log, "AGENT_TOKEN is short") {
		t.Fatalf("a shared token of 32 characters was called short: %s", log)
	}
}

func TestAFreshAgentSaysHowToPairAndPrintsNoCode(t *testing.T) {
	a := startAgent(t)
	log := a.log.String()
	if !strings.Contains(log, "no phone is paired yet") || !strings.Contains(log, "docker-mobile-agent pair") {
		t.Fatalf("log = %s", log)
	}
	if !strings.Contains(log, "fingerprint="+a.fingerprint().Display()) {
		t.Fatalf("the fingerprint is not in the startup log: %s", log)
	}
	if strings.Contains(log, "dockermobile://") {
		t.Fatal("a pairing link was written to the log")
	}
}

func TestTheServerLogDropsFailedHandshakesAndKeepsTheRest(t *testing.T) {
	var out syncBuf
	w := serverLog{slog.New(slog.NewTextHandler(&out, nil))}

	// What net/http writes about a scanner that does not speak TLS.
	handshake := []byte("http: TLS handshake error from 203.0.113.9:40000: tls: first record does not look like a TLS handshake\n")
	if n, err := w.Write(handshake); n != len(handshake) || err != nil {
		t.Fatalf("Write = %d, %v", n, err)
	}
	if out.String() != "" {
		t.Fatalf("a failed handshake was logged: %s", out.String())
	}

	for name, c := range map[string]struct {
		report string
		want   []string // what the log must hold of it
	}{
		"the panic of a handler": {
			"http: panic serving 203.0.113.9:40000: boom\ngoroutine 7 [running]:\nmain.handler()\n",
			[]string{"http: panic serving 203.0.113.9:40000: boom", "main.handler()"},
		},
		"an accept that fails": {
			"http: Accept error: accept tcp [::]:8443: accept4: too many open files; retrying in 1s\n",
			[]string{"http: Accept error: accept tcp [::]:8443: accept4: too many open files; retrying in 1s"},
		},
	} {
		before := out.String()
		if n, err := w.Write([]byte(c.report)); n != len(c.report) || err != nil {
			t.Fatalf("%s: Write = %d, %v", name, n, err)
		}
		logged := strings.TrimPrefix(out.String(), before)
		if !strings.Contains(logged, "level=ERROR") {
			t.Errorf("%s is not logged as an error: %q", name, logged)
		}
		for _, want := range c.want {
			if !strings.Contains(logged, want) {
				t.Errorf("%s: the log lacks %q: %q", name, want, logged)
			}
		}
		if strings.Count(logged, "\n") != 1 {
			t.Errorf("%s does not take exactly one line of the log: %q", name, logged)
		}
	}
}

func TestGarbageOnTheTLSPortLeavesNoLineAndTheAgentKeepsServing(t *testing.T) {
	a := startAgent(t)
	conn, err := net.Dial("tcp", a.addr)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	if _, err := conn.Write([]byte("this is not a TLS handshake\r\n")); err != nil {
		t.Fatal(err)
	}
	// The agent gives the connection up; by then it has reported whatever it
	// reports about it.
	if _, err := io.Copy(io.Discard, conn); errors.Is(err, os.ErrDeadlineExceeded) {
		t.Fatal("the agent kept a connection that does not speak TLS")
	}
	if got := a.pinned("").status("GET", "/healthz"); got != http.StatusOK {
		t.Fatalf("after the garbage: /healthz = %d, want 200", got)
	}
	if log := a.log.String(); strings.Contains(log, "handshake") || strings.Contains(log, "level=ERROR") {
		t.Fatalf("the failed handshake is in the log: %s", log)
	}
}

func TestTheFingerprintCommandPrintsWhatThePortPresents(t *testing.T) {
	a := startAgent(t)
	p := newPhone(t, "https", a.addr)
	p.status("GET", "/healthz")
	code, out, errOut := a.command("fingerprint")
	if code != 0 || strings.TrimSpace(out) != p.presented().Display() {
		t.Fatalf("fingerprint: exit %d, %q (stderr %q); the port presents %q", code, out, errOut, p.presented().Display())
	}
}

func TestHealthcheck(t *testing.T) {
	a := startAgent(t)
	if code, _, errOut := a.command("healthcheck"); code != 0 {
		t.Fatalf("healthcheck of a running agent failed: %s", errOut)
	}
	a.stop()
	if code, _, _ := a.command("healthcheck"); code != 1 {
		t.Fatalf("healthcheck of a stopped agent: exit %d, want 1", code)
	}
}

func TestPlainHTTPMode(t *testing.T) {
	a := startAgent(t, "AGENT_INSECURE_HTTP", "1", "AGENT_ADVERTISE", "https://docker.example.com", "AGENT_TOKEN", shared)
	if !strings.Contains(a.log.String(), "serving plain HTTP") {
		t.Fatalf("no warning about plain HTTP in the log: %s", a.log.String())
	}
	p := newPhone(t, "http", a.addr)
	p.token = shared
	if got := p.status("GET", "/containers/json"); got != http.StatusOK {
		t.Fatalf("code = %d, want 200", got)
	}
	if code, _, errOut := a.command("healthcheck"); code != 0 {
		t.Fatalf("healthcheck failed: %s", errOut)
	}
	if code, _, errOut := a.command("fingerprint"); code != 1 || !strings.Contains(errOut, "no certificate") {
		t.Fatalf("fingerprint in plain-HTTP mode: %d %q", code, errOut)
	}
	if _, err := os.Stat(filepath.Join(a.env["AGENT_DATA"], "tls.key")); !os.IsNotExist(err) {
		t.Fatal("plain-HTTP mode created a TLS key")
	}
}

func TestStoppingTheAgentEndsStreamsAndCleansUp(t *testing.T) {
	a := startAgent(t, "AGENT_TOKEN", shared)
	before := a.fingerprint()
	p := a.pinned(shared)
	stream, err := p.do("GET", "/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Body.Close()
	if _, err := io.ReadFull(stream.Body, make([]byte, 1)); err != nil {
		t.Fatalf("the stream did not start: %v", err)
	}

	began := time.Now()
	if err := a.stop(); err != nil {
		t.Fatalf("serve returned %v", err)
	}
	if took := time.Since(began); took > 3*time.Second {
		t.Fatalf("stopping took %v", took)
	}
	ended := make(chan struct{})
	go func() {
		io.Copy(io.Discard, stream.Body)
		close(ended)
	}()
	select {
	case <-ended:
	case <-time.After(3 * time.Second):
		t.Fatal("the stream outlived the agent")
	}
	if _, err := os.Stat(filepath.Join(a.env["AGENT_DATA"], "admin.sock")); !os.IsNotExist(err) {
		t.Fatalf("the admin socket was left behind: %v", err)
	}

	// The same folder starts again with the same identity.
	again := startAgent(t, "AGENT_DATA", a.env["AGENT_DATA"], "AGENT_TOKEN", shared)
	if again.fingerprint() != before {
		t.Fatal("the fingerprint changed across a restart")
	}
	if got := again.pinned(shared).status("GET", "/containers/json"); got != http.StatusOK {
		t.Fatalf("after a restart: %d, want 200", got)
	}
}

func TestStoppingTheAgentEndsAnOpenTerminal(t *testing.T) {
	// A terminal is a connection the handler has taken over: stopping the
	// HTTP server neither waits for it nor closes it.
	a := startAgent(t, "AGENT_TOKEN", shared)
	p := a.pinned(shared)
	dialer := websocket.Dialer{
		TLSClientConfig:  p.client.Transport.(*http.Transport).TLSClientConfig,
		HandshakeTimeout: 3 * time.Second,
	}
	id := strings.Repeat("0123456789abcdef", 4)
	ws, _, err := dialer.Dial("wss://"+a.addr+"/exec/"+id+"/ws", http.Header{"Authorization": {"Bearer " + p.token}})
	if err != nil {
		t.Fatalf("open the terminal: %v", err)
	}
	defer ws.Close()
	ws.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, data, err := ws.ReadMessage(); err != nil || string(data) != terminalGreeting {
		t.Fatalf("the terminal is not through to the daemon: %q, %v", data, err)
	}
	ws.SetReadDeadline(time.Time{})

	if err := a.stop(); err != nil {
		t.Fatalf("serve returned %v", err)
	}
	// The daemon sends nothing more, so a read that returns means that the
	// terminal is over.
	ended := make(chan struct{})
	go func() {
		ws.ReadMessage()
		close(ended)
	}()
	select {
	case <-ended:
	case <-time.After(3 * time.Second):
		t.Fatal("the terminal outlived the agent")
	}
}

// secondAgentTimeout is how long a second agent on a folder that is in use
// may take to be refused. It is refused at once. One that was let in would
// serve until its context ends: the timeout ends it, and with it the test.
const secondAgentTimeout = 3 * time.Second

func TestASecondAgentOnTheSameFolderIsRefused(t *testing.T) {
	a := startAgent(t)
	env := func(k string) string {
		if k == "AGENT_LISTEN" {
			return "127.0.0.1:0"
		}
		return a.env[k]
	}
	ctx, cancel := context.WithTimeout(context.Background(), secondAgentTimeout)
	defer cancel()
	var errOut bytes.Buffer
	if code := run(ctx, []string{"serve"}, env, io.Discard, &errOut); code != 1 || !strings.Contains(errOut.String(), "already running") {
		t.Fatalf("a second agent: exit %d, %s", code, errOut.String())
	}
}

func TestASecondAgentIsRefusedBeforeItTouchesTheState(t *testing.T) {
	a := startAgent(t)
	// Damage the device list on disk. A second agent that read the state
	// before taking the admin socket would stop on this file instead.
	if err := os.WriteFile(filepath.Join(a.env["AGENT_DATA"], "devices.json"), []byte("{"), 0o600); err != nil {
		t.Fatal(err)
	}
	// And take the certificate away. A second agent that loaded its identity
	// before taking the admin socket would issue a new one.
	certificate := filepath.Join(a.env["AGENT_DATA"], "tls.crt")
	if err := os.Remove(certificate); err != nil {
		t.Fatal(err)
	}
	env := func(k string) string {
		if k == "AGENT_LISTEN" {
			return "127.0.0.1:0"
		}
		return a.env[k]
	}
	ctx, cancel := context.WithTimeout(context.Background(), secondAgentTimeout)
	defer cancel()
	var errOut bytes.Buffer
	if code := run(ctx, []string{"serve"}, env, io.Discard, &errOut); code != 1 || !strings.Contains(errOut.String(), "already running") {
		t.Fatalf("a second agent: exit %d, %s", code, errOut.String())
	}
	if _, err := os.Stat(certificate); !os.IsNotExist(err) {
		t.Fatalf("the agent that was refused wrote a certificate: %v", err)
	}
}

func TestTheStateFolderStaysLockedUntilRequestsHaveStopped(t *testing.T) {
	// A longer grace for this test: with a stream open, stopping takes all
	// of it, which leaves time to try a second agent meanwhile.
	old := shutdownGrace
	shutdownGrace = 2 * time.Second
	t.Cleanup(func() { shutdownGrace = old })

	a := startAgent(t, "AGENT_TOKEN", shared)
	stream, err := a.pinned(shared).do("GET", "/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Body.Close()
	if _, err := io.ReadFull(stream.Body, make([]byte, 1)); err != nil {
		t.Fatalf("the stream did not start: %v", err)
	}

	// A pair command that waits for its phone.
	waiting := make(chan struct{})
	pairEnded := make(chan error, 1)
	go func() {
		pairEnded <- admin.NewClient(a.env["AGENT_DATA"]).Pair(context.Background(), admin.PairRequest{}, func(e admin.Event) {
			if e.Event == admin.EventStarted {
				close(waiting)
			}
		})
	}()
	select {
	case <-waiting:
	case err := <-pairEnded:
		t.Fatalf("the pairing ended before it began to wait: %v", err)
	case <-time.After(3 * time.Second):
		t.Fatal("the pairing did not start")
	}

	a.cancel()
	waitFor(t, "the agent to begin stopping", func() bool { return strings.Contains(a.log.String(), "stopping") })

	// The pair command hears of it now, not when the grace is over.
	select {
	case err := <-pairEnded:
		if !errors.Is(err, admin.ErrStopped) {
			t.Fatalf("the waiting pairing ended with %v, want %v", err, admin.ErrStopped)
		}
	case <-time.After(time.Second):
		t.Fatal("the waiting pairing did not end when the agent began to stop")
	}

	// The first agent is still letting its stream finish. A second one on the
	// same folder must be refused now; if it were let in, it would serve
	// until its own context ends and exit cleanly.
	env := func(k string) string {
		if k == "AGENT_LISTEN" {
			return "127.0.0.1:0"
		}
		return a.env[k]
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	var errOut bytes.Buffer
	if code := run(ctx, []string{"serve"}, env, io.Discard, &errOut); code != 1 || !strings.Contains(errOut.String(), "already running") {
		t.Fatalf("a second agent while the first is stopping: exit %d, %s", code, errOut.String())
	}
	if err := a.stop(); err != nil {
		t.Fatalf("serve returned %v", err)
	}
}

func TestAPortInUseIsAClearError(t *testing.T) {
	a := startAgent(t)
	dataDir, err := os.MkdirTemp("", "dma")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dataDir)
	env := func(k string) string {
		switch k {
		case "AGENT_DATA":
			return dataDir
		case "AGENT_LISTEN":
			return a.addr
		}
		return ""
	}
	var errOut bytes.Buffer
	if code := run(context.Background(), nil, env, io.Discard, &errOut); code != 1 || !strings.Contains(errOut.String(), "listen on "+a.addr) {
		t.Fatalf("a port in use: exit %d, %s", code, errOut.String())
	}
	if _, err := os.Stat(filepath.Join(dataDir, "admin.sock")); !os.IsNotExist(err) {
		t.Fatal("the admin socket was left behind after a failed start")
	}
}

func TestAnUnusableStateFolderIsAClearError(t *testing.T) {
	notAFolder := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(notAFolder, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	env := func(k string) string {
		switch k {
		case "AGENT_DATA":
			return notAFolder
		case "AGENT_LISTEN":
			return "127.0.0.1:0"
		}
		return ""
	}
	var errOut bytes.Buffer
	if code := run(context.Background(), nil, env, io.Discard, &errOut); code != 1 || !strings.Contains(errOut.String(), "state folder") {
		t.Fatalf("exit %d: %s", code, errOut.String())
	}
}

func TestAnAgentStartsAgainOnTheFolderItHasUsed(t *testing.T) {
	a := startAgent(t)
	link, _, _, exit := a.startPair()
	p := newPhone(t, "https", a.addr)
	if status, err := p.pairWithLink(link, "Pixel 8"); err != nil || status != http.StatusOK {
		t.Fatalf("pairing by link: %d, %v", status, err)
	}
	if got := exited(t, exit); got != 0 {
		t.Fatalf("pair exited %d", got)
	}
	if err := a.stop(); err != nil {
		t.Fatalf("serve returned %v", err)
	}
	// The folder holds what an agent leaves in it: the device list, the key,
	// the certificate and the lock file. A folder is taken only when all that
	// is in it is the agent's own, and all of this is.
	dataDir := a.env["AGENT_DATA"]
	for _, name := range []string{"devices.json", "tls.key", "tls.crt", "agent.lock"} {
		if _, err := os.Stat(filepath.Join(dataDir, name)); err != nil {
			t.Fatalf("the folder the agent has used lacks %s: %v", name, err)
		}
	}
	again := startAgent(t, "AGENT_DATA", dataDir)
	p.addr = again.addr
	if got := p.status("GET", "/containers/json"); got != http.StatusOK {
		t.Fatalf("the paired phone after the agent started again: %d, want 200", got)
	}
}

// commandCase is one command line and what it must produce.
type commandCase struct {
	name     string
	args     []string
	env      []string // key, value pairs on top of an empty state folder
	code     int
	inStdout string
	inStderr string
	stderrIs string // when not empty, all that standard error may hold
}

func runCommandCases(t *testing.T, cases []commandCase) {
	t.Helper()
	for _, c := range cases {
		m := map[string]string{"AGENT_DATA": t.TempDir()}
		for i := 0; i+1 < len(c.env); i += 2 {
			m[c.env[i]] = c.env[i+1]
		}
		var out, errOut bytes.Buffer
		code := run(context.Background(), c.args, func(k string) string { return m[k] }, &out, &errOut)
		if code != c.code {
			t.Errorf("%s: exit %d, want %d (stderr: %s)", c.name, code, c.code, errOut.String())
		}
		if c.inStdout != "" && !strings.Contains(out.String(), c.inStdout) {
			t.Errorf("%s: stdout lacks %q: %s", c.name, c.inStdout, out.String())
		}
		if c.inStderr != "" && !strings.Contains(errOut.String(), c.inStderr) {
			t.Errorf("%s: stderr lacks %q: %s", c.name, c.inStderr, errOut.String())
		}
		if c.stderrIs != "" && errOut.String() != c.stderrIs {
			t.Errorf("%s: stderr is %q, want %q", c.name, errOut.String(), c.stderrIs)
		}
	}
}

func TestCommandLine(t *testing.T) {
	runCommandCases(t, []commandCase{
		{name: "unknown command", args: []string{"frobnicate"}, code: 2, inStderr: `unknown command "frobnicate"`},
		{name: "help", args: []string{"help"}, code: 0, inStdout: "docker-mobile-agent fingerprint"},
		{name: "help lists itself", args: []string{"help"}, code: 0, inStdout: "docker-mobile-agent help "},
		{name: "help says how the switch for plain HTTP is read", args: []string{"help"}, code: 0, inStdout: "AGENT_INSECURE_HTTP   1, true, yes or on: serve plain HTTP"},
		{name: "version", args: []string{"version"}, code: 0, inStdout: "docker-mobile-agent dev (commit "},
		{name: "fingerprint before the first run", args: []string{"fingerprint"}, code: 1, inStderr: "no certificate"},
		{name: "a short shared token", env: []string{"AGENT_TOKEN", "too-short"}, code: 1, inStderr: "AGENT_TOKEN is too short: use at least 16 characters"},
		{name: "a bad listen address", args: []string{"serve"}, env: []string{"AGENT_LISTEN", "nope"}, code: 1, inStderr: "AGENT_LISTEN"},
		{name: "a bad flag for serve", args: []string{"--verbose"}, code: 1,
			stderrIs: "docker-mobile-agent: serve: flag provided but not defined: -verbose (see: docker-mobile-agent serve --help)\n"},
		{name: "a bad flag for healthcheck", args: []string{"healthcheck", "--verbose"}, code: 1,
			stderrIs: "docker-mobile-agent: healthcheck: flag provided but not defined: -verbose (see: docker-mobile-agent healthcheck --help)\n"},
		{name: "healthcheck without an agent", args: []string{"healthcheck", "--insecure-http"}, env: []string{"AGENT_LISTEN", "127.0.0.1:1"}, code: 1},
		{name: "serve with a stray argument", args: []string{"serve", "extra"}, code: 1,
			stderrIs: "docker-mobile-agent: serve: unexpected argument \"extra\" (see: docker-mobile-agent serve --help)\n"},
		{name: "a command after a flag", args: []string{"--insecure-http", "healthcheck"}, code: 1, inStderr: `serve: unexpected argument "healthcheck"`},
		{name: "fingerprint with a stray argument", args: []string{"fingerprint", "extra"}, code: 1, inStderr: `fingerprint: unexpected argument "extra"`},
		{name: "healthcheck with a stray argument", args: []string{"healthcheck", "extra"}, code: 1, inStderr: `healthcheck: unexpected argument "extra"`},
		{name: "version with a stray argument", args: []string{"version", "extra"}, code: 1, inStderr: `version: unexpected argument "extra"`},
	})
}

func TestHelpAtTheTopIsTheUsageText(t *testing.T) {
	for _, args := range [][]string{{"--help"}, {"-h"}, {"help"}} {
		var out, errOut bytes.Buffer
		code := run(context.Background(), args, func(string) string { return "" }, &out, &errOut)
		if code != 0 || out.String() != usage || errOut.Len() != 0 {
			t.Errorf("%v: exit %d, stdout %q, stderr %q", args, code, out.String(), errOut.String())
		}
	}
}

func TestEveryCommandShowsItsOwnHelp(t *testing.T) {
	for _, c := range []struct {
		command  string
		synopsis string   // how the command is called, as the usage text has it
		flags    []string // every flag with its description, as the help shows it
	}{
		{"serve", "docker-mobile-agent [serve] [--insecure-http]", []string{
			"  --insecure-http\n        serve plain HTTP, behind a proxy that terminates TLS\n",
		}},
		{"pair", "docker-mobile-agent pair [--read-only] [--name NAME] [--host ADDR] [--invert] [--no-qr]", []string{
			"  --read-only\n        pair a phone that may look but not change anything\n",
			"  --name NAME\n        NAME for the phone (default: what the phone calls itself)\n",
			"  --host ADDR\n        ADDR at which phones reach this agent, host or host:port\n",
			"  --invert\n        draw the QR code for a light terminal\n",
			"  --no-qr\n        do not draw the QR code\n",
		}},
		{"devices", "docker-mobile-agent devices", nil},
		{"revoke", "docker-mobile-agent revoke ID", nil},
		{"fingerprint", "docker-mobile-agent fingerprint", nil},
		{"healthcheck", "docker-mobile-agent healthcheck [--insecure-http]", []string{
			"  --insecure-http\n        the agent serves plain HTTP\n",
		}},
		{"version", "docker-mobile-agent version", nil},
	} {
		if !strings.Contains(usage, "\n  "+c.synopsis) {
			t.Errorf("%s: the usage text does not show the command as %q", c.command, c.synopsis)
		}
		for _, help := range []string{"--help", "-h"} {
			var out, errOut bytes.Buffer
			// No environment: a command that did more than show its help
			// would fail on it, or would not return.
			code := run(context.Background(), []string{c.command, help}, func(string) string { return "" }, &out, &errOut)
			if code != 0 || errOut.Len() != 0 {
				t.Errorf("%s %s: exit %d, stderr %q", c.command, help, code, errOut.String())
			}
			if !strings.HasPrefix(out.String(), "Usage: "+c.synopsis+"\n") {
				t.Errorf("%s %s: the help does not begin with how the command is called: %q", c.command, help, out.String())
			}
			for _, want := range c.flags {
				if !strings.Contains(out.String(), want) {
					t.Errorf("%s %s: the help lacks %q: %q", c.command, help, want, out.String())
				}
			}
			if strings.Contains(out.String(), "Flags:") != (len(c.flags) > 0) {
				t.Errorf("%s %s: the help is wrong about whether the command has flags: %q", c.command, help, out.String())
			}
		}
	}
}
