package server

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/conns"
	"github.com/retransmit/docker-mobile/agent/internal/pairing"
	"github.com/retransmit/docker-mobile/agent/internal/state"
	"github.com/retransmit/docker-mobile/agent/internal/throttle"
)

const legacy = "a-shared-token-of-enough-length"

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
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

// daemon is a fake Docker daemon that records what reaches it.
type daemon struct {
	*httptest.Server
	mu   sync.Mutex
	seen []string
}

func newDaemon(t *testing.T) *daemon {
	t.Helper()
	d := &daemon{}
	d.Server = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		body, _ := io.ReadAll(r.Body)
		d.mu.Lock()
		d.seen = append(d.seen, r.Method+" "+r.URL.EscapedPath()+" "+r.Header.Get("Authorization")+" "+string(body))
		d.mu.Unlock()
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`[{"Id":"x"}]`))
	}))
	t.Cleanup(d.Close)
	return d
}

func (d *daemon) requests() []string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return append([]string(nil), d.seen...)
}

type fixture struct {
	handler http.Handler
	devices *state.Devices
	pairing *pairing.Manager
	conns   *conns.Registry
	clock   *clock
	daemon  *daemon
	log     *bytes.Buffer
	fp      []byte
}

func newFixture(t *testing.T, legacyToken string, fingerprint []byte) *fixture {
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
	f := &fixture{
		devices: devices,
		pairing: pairing.NewManager(c.now, rand.Reader),
		conns:   conns.New(),
		clock:   c,
		daemon:  newDaemon(t),
		log:     &bytes.Buffer{},
		fp:      fingerprint,
	}
	f.handler, err = New(Options{
		DockerHost:  "tcp://" + f.daemon.Listener.Addr().String(),
		Devices:     devices,
		LegacyToken: legacyToken,
		Pairing:     f.pairing,
		Fingerprint: fingerprint,
		Limiter:     throttle.New(c.now),
		Conns:       f.conns,
		Version:     "1.2.3",
		Log:         slog.New(slog.NewTextHandler(f.log, nil)),
		Now:         c.now,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return f
}

func (f *fixture) do(method, path, token string, body io.Reader, headers ...string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, path, body)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	for i := 0; i+1 < len(headers); i += 2 {
		req.Header.Set(headers[i], headers[i+1])
	}
	rec := httptest.NewRecorder()
	f.handler.ServeHTTP(rec, req)
	return rec
}

func message(t *testing.T, rec *httptest.ResponseRecorder) string {
	t.Helper()
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil {
		t.Fatalf("body is not a JSON message: %q", rec.Body.String())
	}
	return body["message"]
}

var agentFP = bytes.Repeat([]byte{7}, 32)

func TestHealthzIsOpenAndSaysOnlyOk(t *testing.T) {
	f := newFixture(t, "", agentFP)
	rec := f.do("GET", "/healthz", "", nil)
	if rec.Code != http.StatusOK || rec.Body.String() != "ok" {
		t.Fatalf("healthz = %d %q", rec.Code, rec.Body.String())
	}
	if f.log.Len() != 0 {
		t.Fatalf("the health check was logged: %s", f.log.String())
	}
}

func TestTheProxyNeedsCredentials(t *testing.T) {
	f := newFixture(t, legacy, agentFP)
	if rec := f.do("GET", "/containers/json", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("code = %d, want 401", rec.Code)
	}
	if rec := f.do("GET", "/exec/abc/ws", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("the terminal route without a token: code = %d, want 401", rec.Code)
	}
	if rec := f.do("GET", "/containers/json", legacy, nil); rec.Code != http.StatusOK {
		t.Fatalf("shared token: code = %d, want 200", rec.Code)
	}
	_, token, _ := f.devices.Add("phone", state.RoleFull)
	if rec := f.do("POST", "/v1.45/containers/abc/start", token, nil); rec.Code != http.StatusOK {
		t.Fatalf("device token: code = %d, want 200", rec.Code)
	}
	if n := len(f.daemon.requests()); n != 2 {
		t.Fatalf("%d requests reached the daemon, want 2", n)
	}
}

func TestAReadOnlyDeviceReadsButCannotChangeAnything(t *testing.T) {
	f := newFixture(t, "", agentFP)
	_, token, _ := f.devices.Add("viewer", state.RoleReadOnly)
	for _, path := range []string{"/containers/json", "/v1.45/containers/abc/logs", "/events", "/agent/v1/whoami"} {
		if rec := f.do("GET", path, token, nil); rec.Code != http.StatusOK {
			t.Errorf("GET %s: code = %d, want 200", path, rec.Code)
		}
	}
	before := len(f.daemon.requests())
	refused := []struct{ method, path string }{
		{"POST", "/containers/abc/start"},
		{"DELETE", "/v1.45/containers/abc"},
		{"POST", "/containers/abc/exec"},
		{"GET", "/containers/abc/archive"},
		{"GET", "/exec/abc/ws"},
		{"GET", "/containers/abc%2Fjson"},
	}
	for _, r := range refused {
		rec := f.do(r.method, r.path, token, nil)
		if rec.Code != http.StatusForbidden || message(t, rec) != ReadOnlyMessage {
			t.Errorf("%s %s: %d %q, want 403 with the read-only message", r.method, r.path, rec.Code, rec.Body.String())
		}
	}
	// A path with dot segments is redirected by the router before any
	// handler sees it; it must not come back as a success either.
	if rec := f.do("GET", "/containers/../containers/abc/start", token, nil); rec.Code == http.StatusOK {
		t.Fatalf("a path with dot segments was served: %d", rec.Code)
	}
	if after := len(f.daemon.requests()); after != before {
		t.Fatalf("%d refused requests reached the daemon", after-before)
	}
}

func TestWhoami(t *testing.T) {
	f := newFixture(t, legacy, agentFP)
	dev, token, _ := f.devices.Add("Pixel 8", state.RoleReadOnly)
	rec := f.do("GET", "/agent/v1/whoami", token, nil)
	var got whoamiResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatalf("body = %q", rec.Body.String())
	}
	if got.Device.ID != dev.ID || got.Device.Name != "Pixel 8" || got.Device.Role != "readonly" || got.Agent.Version != "1.2.3" || got.Agent.API != 1 {
		t.Fatalf("whoami = %+v", got)
	}
	rec = f.do("GET", "/agent/v1/whoami", legacy, nil)
	json.Unmarshal(rec.Body.Bytes(), &got)
	if got.Device.ID != "env" || got.Device.Role != "full" {
		t.Fatalf("whoami with the shared token = %+v", got)
	}
	if rec := f.do("GET", "/agent/v1/whoami", "", nil); rec.Code != http.StatusUnauthorized {
		t.Fatalf("whoami without credentials: %d", rec.Code)
	}
}

func TestUnknownAgentPathsNeverReachDocker(t *testing.T) {
	f := newFixture(t, legacy, agentFP)
	for _, path := range []string{"/agent/v1/devices", "/agent/v2/whoami", "/agent/", "/agent/v1/pair"} {
		if rec := f.do("GET", path, legacy, nil); rec.Code != http.StatusNotFound {
			t.Errorf("GET %s: code = %d, want 404", path, rec.Code)
		}
	}
	if n := len(f.daemon.requests()); n != 0 {
		t.Fatalf("%d requests reached the daemon", n)
	}
}

func TestARequestFromAWebPageIsRefused(t *testing.T) {
	f := newFixture(t, legacy, agentFP)
	for _, path := range []string{"/containers/json", "/healthz", "/agent/v1/pair"} {
		rec := f.do("GET", path, legacy, nil, "Origin", "https://evil.example")
		if rec.Code != http.StatusForbidden {
			t.Errorf("%s with an Origin header: code = %d, want 403", path, rec.Code)
		}
	}
	if n := len(f.daemon.requests()); n != 0 {
		t.Fatalf("%d requests reached the daemon", n)
	}
}

func TestBodiesAreCappedExceptOnUploadRoutes(t *testing.T) {
	f := newFixture(t, legacy, agentFP)
	big := strings.NewReader(strings.Repeat("x", maxBody+1))
	rec := f.do("POST", "/containers/create", legacy, big)
	if rec.Code != http.StatusRequestEntityTooLarge || message(t, rec) != "The request body is too large" {
		t.Fatalf("an oversized body: %d %q, want 413", rec.Code, rec.Body.String())
	}
	big = strings.NewReader(strings.Repeat("x", maxBody+1))
	if rec := f.do("POST", "/v1.45/images/load", legacy, big); rec.Code != http.StatusOK {
		t.Fatalf("an upload was refused: %d", rec.Code)
	}
	small := strings.NewReader(`{"Image":"nginx"}`)
	if rec := f.do("POST", "/containers/create", legacy, small); rec.Code != http.StatusOK {
		t.Fatalf("a normal body was refused: %d", rec.Code)
	}
}

func TestTheTokenNeverReachesTheDaemon(t *testing.T) {
	f := newFixture(t, legacy, agentFP)
	_, token, _ := f.devices.Add("phone", state.RoleFull)
	f.do("GET", "/containers/json", legacy, nil)
	f.do("GET", "/containers/json", token, nil)
	seen := f.daemon.requests()
	if len(seen) != 2 {
		t.Fatalf("%d requests reached the daemon, want 2", len(seen))
	}
	for _, line := range seen {
		if strings.Contains(line, "Bearer") || strings.Contains(line, legacy) {
			t.Fatalf("the daemon saw credentials: %s", line)
		}
	}
}

func TestTheAccessLogNamesTheDeviceAndHidesSecrets(t *testing.T) {
	f := newFixture(t, legacy, agentFP)
	dev, token, _ := f.devices.Add("Pixel 8", state.RoleFull)
	f.do("GET", "/containers/json?filters=secret-looking-value", token, nil)
	line := f.log.String()
	for _, want := range []string{"device=" + dev.ID, `name="Pixel 8"`, "method=GET", "path=/containers/json", "status=200"} {
		if !strings.Contains(line, want) {
			t.Errorf("log line lacks %s: %s", want, line)
		}
	}
	secret := token[strings.LastIndex(token, ".")+1:]
	for _, never := range []string{secret, "secret-looking-value", "Bearer"} {
		if strings.Contains(line, never) {
			t.Errorf("log line contains %q: %s", never, line)
		}
	}
}

func TestFailedAuthenticationsAreLoggedOncePerSecondPerAddress(t *testing.T) {
	f := newFixture(t, legacy, agentFP)
	for i := 0; i < 3; i++ {
		f.do("GET", "/containers/json", "wrong", nil)
	}
	if n := strings.Count(f.log.String(), "authentication failed"); n != 1 {
		t.Fatalf("%d failure lines within a second, want 1", n)
	}
	f.clock.advance(time.Second)
	f.do("GET", "/containers/json", "wrong", nil)
	if n := strings.Count(f.log.String(), "authentication failed"); n != 2 {
		t.Fatalf("%d failure lines, want 2", n)
	}
	if !strings.Contains(f.log.String(), "from=192.0.2.1") {
		t.Fatalf("the source address is missing: %s", f.log.String())
	}
}

// pair runs the phone's side of a pairing against the handler.
func (f *fixture) pair(t *testing.T, code string, seenFP []byte, name string) (*httptest.ResponseRecorder, []byte) {
	t.Helper()
	nonce := make([]byte, pairing.NonceLen)
	rand.Read(nonce)
	body, _ := json.Marshal(pairRequest{
		V:     1,
		Nonce: base64.RawURLEncoding.EncodeToString(nonce),
		Proof: base64.RawURLEncoding.EncodeToString(pairing.PhoneProof(code, seenFP, nonce)),
		Name:  name,
	})
	return f.do("POST", "/agent/v1/pair", "", bytes.NewReader(body)), nonce
}

func TestPairingIssuesATokenAndProvesTheAgentHoldsTheCode(t *testing.T) {
	f := newFixture(t, "", agentFP)
	p, done, _ := f.pairing.Start(state.RoleReadOnly, "")
	rec, nonce := f.pair(t, p.Code, agentFP, "Pixel 8")
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d %s", rec.Code, rec.Body.String())
	}
	var got pairResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil {
		t.Fatal(err)
	}
	agentNonce, _ := base64.RawURLEncoding.DecodeString(got.Nonce)
	proof, _ := base64.RawURLEncoding.DecodeString(got.Proof)
	if !bytes.Equal(proof, pairing.AgentProof(p.Code, agentFP, nonce, agentNonce)) {
		t.Fatal("the agent's proof does not verify")
	}
	if got.Device.Name != "Pixel 8" || got.Device.Role != "readonly" || got.Agent.Version != "1.2.3" {
		t.Fatalf("response = %+v", got)
	}
	if rec := f.do("GET", "/containers/json", got.Token, nil); rec.Code != http.StatusOK {
		t.Fatalf("the issued token does not authenticate: %d", rec.Code)
	}
	if rec := f.do("POST", "/containers/x/start", got.Token, nil); rec.Code != http.StatusForbidden {
		t.Fatalf("the issued token is not read-only: %d", rec.Code)
	}
	if r := <-done; r.Outcome != pairing.Paired {
		t.Fatalf("result = %+v", r)
	}
	if rec.Header().Get("Cache-Control") != "no-store" {
		t.Fatal("the response with the token may be cached")
	}
	if strings.Contains(f.log.String(), got.Token) || strings.Contains(f.log.String(), p.Code) {
		t.Fatal("the token or the code is in the log")
	}
}

func TestPairingAnswersNothingUsefulWithoutAPendingPairing(t *testing.T) {
	f := newFixture(t, "", agentFP)
	rec, _ := f.pair(t, "K7QM2XPA9TRC", agentFP, "x")
	if rec.Code != http.StatusNotFound {
		t.Fatalf("code = %d, want 404", rec.Code)
	}
}

func TestAProofBoundToAnotherCertificateIsRefused(t *testing.T) {
	f := newFixture(t, "", agentFP)
	p, _, _ := f.pairing.Start(state.RoleFull, "")
	rec, _ := f.pair(t, p.Code, bytes.Repeat([]byte{8}, 32), "x")
	if rec.Code != http.StatusForbidden {
		t.Fatalf("code = %d, want 403", rec.Code)
	}
	if len(f.devices.List()) != 0 {
		t.Fatal("a device was created")
	}
}

func TestMalformedPairingRequestsAreRefused(t *testing.T) {
	f := newFixture(t, "", agentFP)
	f.pairing.Start(state.RoleFull, "")
	ok := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	for name, body := range map[string]string{
		"not json":      "{",
		"wrong version": `{"v":2,"nonce":"` + ok + `","proof":"` + ok + `"}`,
		"no version":    `{"nonce":"` + ok + `","proof":"` + ok + `"}`,
		"short nonce":   `{"v":1,"nonce":"AAAA","proof":"` + ok + `"}`,
		"bad base64":    `{"v":1,"nonce":"***","proof":"` + ok + `"}`,
		"padded base64": `{"v":1,"nonce":"` + ok + `=","proof":"` + ok + `"}`,
		"no proof":      `{"v":1,"nonce":"` + ok + `","proof":""}`,
		"short proof":   `{"v":1,"nonce":"` + ok + `","proof":"` + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 31)) + `"}`,
		"long proof":    `{"v":1,"nonce":"` + ok + `","proof":"` + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 33)) + `"}`,
		"huge":          `{"v":1,"name":"` + strings.Repeat("x", maxPairBody) + `"}`,
	} {
		rec := f.do("POST", "/agent/v1/pair", "", strings.NewReader(body))
		if rec.Code != http.StatusBadRequest {
			t.Errorf("%s: code = %d, want 400", name, rec.Code)
		}
	}
}

func TestWrongPairingProofsCountAgainstTheAddress(t *testing.T) {
	f := newFixture(t, "", agentFP)
	for i := 0; i < throttle.Threshold; i++ {
		f.pairing.Start(state.RoleFull, "") // a fresh pairing, so the try limit is not what stops it
		rec, _ := f.pair(t, "000000000000", agentFP, "x")
		if rec.Code != http.StatusForbidden {
			t.Fatalf("try %d: code = %d, want 403", i+1, rec.Code)
		}
	}
	p, _, _ := f.pairing.Start(state.RoleFull, "")
	rec, _ := f.pair(t, p.Code, agentFP, "x")
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") != "60" {
		t.Fatalf("the right code from a blocked address: %d, Retry-After %q", rec.Code, rec.Header().Get("Retry-After"))
	}
	f.clock.advance(time.Minute)
	if rec, _ := f.pair(t, p.Code, agentFP, "x"); rec.Code != http.StatusOK {
		t.Fatalf("after the block: code = %d, want 200", rec.Code)
	}
}

func TestPairingWithoutACertificateBindsToAnEmptyFingerprint(t *testing.T) {
	f := newFixture(t, "", nil)
	p, _, _ := f.pairing.Start(state.RoleFull, "")
	if rec, _ := f.pair(t, p.Code, nil, "x"); rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
}

func TestAskingWhileNothingIsPendingCountsAgainstTheAddress(t *testing.T) {
	f := newFixture(t, "", agentFP)
	// A well-formed request with a proof that fits no code.
	filler := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	poll := func() *httptest.ResponseRecorder {
		return f.do("POST", "/agent/v1/pair", "", strings.NewReader(`{"v":1,"nonce":"`+filler+`","proof":"`+filler+`"}`))
	}
	for i := 0; i < throttle.Threshold; i++ {
		if rec := poll(); rec.Code != http.StatusNotFound {
			t.Fatalf("poll %d: code = %d, want 404", i+1, rec.Code)
		}
	}
	rec := poll()
	if rec.Code != http.StatusTooManyRequests || rec.Header().Get("Retry-After") != "60" {
		t.Fatalf("a poll past the threshold: %d, Retry-After %q, want 429 and 60", rec.Code, rec.Header().Get("Retry-After"))
	}
	if !strings.Contains(f.log.String(), "authentication failed") {
		t.Fatalf("the polls were not noted: %s", f.log.String())
	}
	// A pairing that starts now is out of the poller's reach: a blocked
	// address is turned away before its proof is looked at, so no try is used.
	p, _, _ := f.pairing.Start(state.RoleFull, "")
	for i := 0; i < pairing.MaxTries; i++ {
		if rec := poll(); rec.Code != http.StatusTooManyRequests {
			t.Fatalf("blocked poll %d: code = %d, want 429", i+1, rec.Code)
		}
	}
	f.clock.advance(time.Minute)
	if rec, _ := f.pair(t, p.Code, agentFP, "x"); rec.Code != http.StatusOK {
		t.Fatalf("the pairing did not outlast the polls: code = %d, want 200", rec.Code)
	}
}

func TestARequestThatIsCutOffStillGetsItsAccessLine(t *testing.T) {
	var log bytes.Buffer
	c := &clock{t: time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)}
	cutOff := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		noteCaller(r, state.Device{ID: "abcd1234", Name: "Pixel 8"})
		w.WriteHeader(http.StatusPartialContent)
		w.Write([]byte("first\n"))
		// What the proxy does when a stream ends before the daemon is done.
		panic(http.ErrAbortHandler)
	})
	h := accessLog(slog.New(slog.NewTextHandler(&log, nil)), c.now, cutOff)
	var got any
	func() {
		defer func() { got = recover() }()
		h.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest("GET", "/containers/abc/logs?follow=1", nil))
	}()
	if got != http.ErrAbortHandler {
		t.Fatalf("the panic arrived as %v, want http.ErrAbortHandler itself", got)
	}
	if n := strings.Count(log.String(), "msg=request"); n != 1 {
		t.Fatalf("%d access lines for a request that was cut off, want 1: %s", n, log.String())
	}
	for _, want := range []string{"device=abcd1234", `name="Pixel 8"`, "method=GET", "path=/containers/abc/logs", "status=206", "bytes=6"} {
		if !strings.Contains(log.String(), want) {
			t.Errorf("log line lacks %s: %s", want, log.String())
		}
	}
}

func TestOnlyTheHealthCheckItselfGoesUnlogged(t *testing.T) {
	f := newFixture(t, "", agentFP)
	dev, token, _ := f.devices.Add("phone", state.RoleFull)
	for _, method := range []string{"GET", "HEAD"} {
		if rec := f.do(method, "/healthz", "", nil); rec.Code != http.StatusOK {
			t.Fatalf("%s /healthz: code = %d, want 200", method, rec.Code)
		}
	}
	if f.log.Len() != 0 {
		t.Fatalf("the health check was logged: %s", f.log.String())
	}
	// Another method on that path is not the health check: with a credential
	// it goes on to the daemon like any other request.
	f.do("POST", "/healthz", token, nil)
	line := f.log.String()
	for _, want := range []string{"msg=request", "device=" + dev.ID, "method=POST", "path=/healthz"} {
		if !strings.Contains(line, want) {
			t.Errorf("log line lacks %s: %s", want, line)
		}
	}
}

func TestAProofOfTheWrongLengthUsesUpNothing(t *testing.T) {
	f := newFixture(t, "", agentFP)
	p, _, _ := f.pairing.Start(state.RoleFull, "")
	nonce := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, pairing.NonceLen))
	// More of them than a pairing has tries, and than an address may fail.
	for i := 0; i < throttle.Threshold; i++ {
		for _, n := range []int{31, 33} {
			proof := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{2}, n))
			rec := f.do("POST", "/agent/v1/pair", "", strings.NewReader(`{"v":1,"nonce":"`+nonce+`","proof":"`+proof+`"}`))
			if rec.Code != http.StatusBadRequest {
				t.Fatalf("a proof of %d bytes: code = %d, want 400", n, rec.Code)
			}
		}
	}
	if strings.Contains(f.log.String(), "authentication failed") {
		t.Fatalf("a malformed request was noted as a failed attempt: %s", f.log.String())
	}
	if rec, _ := f.pair(t, p.Code, agentFP, "x"); rec.Code != http.StatusOK {
		t.Fatalf("the pairing did not outlast the malformed proofs: code = %d, want 200", rec.Code)
	}
}

// requiredOptions is the least New accepts: every option it may be left
// without is left out.
func requiredOptions(t *testing.T) Options {
	t.Helper()
	dir, err := state.Open(filepath.Join(t.TempDir(), "data"))
	if err != nil {
		t.Fatal(err)
	}
	devices, err := state.LoadDevices(dir, time.Now)
	if err != nil {
		t.Fatal(err)
	}
	return Options{
		DockerHost: "tcp://127.0.0.1:1",
		Devices:    devices,
		Pairing:    pairing.NewManager(time.Now, rand.Reader),
		Limiter:    throttle.New(time.Now),
	}
}

func TestNewNamesTheRequiredOptionThatIsMissing(t *testing.T) {
	for name, without := range map[string]func(*Options){
		"Devices": func(o *Options) { o.Devices = nil },
		"Pairing": func(o *Options) { o.Pairing = nil },
		"Limiter": func(o *Options) { o.Limiter = nil },
	} {
		o := requiredOptions(t)
		without(&o)
		h, err := New(o)
		if err == nil || h != nil {
			t.Errorf("New without %s built a handler", name)
			continue
		}
		if !strings.Contains(err.Error(), name) {
			t.Errorf("New without %s: the error does not name it: %v", name, err)
		}
	}
	// With several missing, the first one is named.
	if _, err := New(Options{DockerHost: "tcp://127.0.0.1:1"}); err == nil || !strings.Contains(err.Error(), "Devices") {
		t.Errorf("New with nothing but a Docker host: error = %v, want one that names Devices", err)
	}
}

func TestAHandlerWorksWithTheRequiredOptionsAlone(t *testing.T) {
	o := requiredOptions(t)
	h, err := New(o)
	if err != nil {
		t.Fatalf("New with the required options alone: %v", err)
	}
	do := func(method, path, token, body string) *httptest.ResponseRecorder {
		req := httptest.NewRequest(method, path, strings.NewReader(body))
		if token != "" {
			req.Header.Set("Authorization", "Bearer "+token)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, req)
		return rec
	}
	dev, token, _ := o.Devices.Add("phone", state.RoleReadOnly)
	if rec := do("GET", "/agent/v1/whoami", token, ""); rec.Code != http.StatusOK || !strings.Contains(rec.Body.String(), dev.ID) {
		t.Fatalf("whoami: %d %s", rec.Code, rec.Body.String())
	}
	if rec := do("GET", "/agent/v1/whoami", "wrong", ""); rec.Code != http.StatusUnauthorized {
		t.Fatalf("a wrong token: code = %d, want 401", rec.Code)
	}
	filler := base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{1}, 32))
	if rec := do("POST", "/agent/v1/pair", "", `{"v":1,"nonce":"`+filler+`","proof":"`+filler+`"}`); rec.Code != http.StatusNotFound {
		t.Fatalf("pairing with nothing pending: code = %d, want 404", rec.Code)
	}
}

func TestTheFailureWarningNamesTheAddressItself(t *testing.T) {
	f := newFixture(t, legacy, agentFP)
	fail := func(remoteAddr string) {
		req := httptest.NewRequest("GET", "/containers/json", nil)
		req.RemoteAddr = remoteAddr
		req.Header.Set("Authorization", "Bearer wrong")
		f.handler.ServeHTTP(httptest.NewRecorder(), req)
	}
	fail("[2001:db8:1:2::7]:50000")
	if !strings.Contains(f.log.String(), "from=2001:db8:1:2::7\n") {
		t.Fatalf("the warning does not name the address: %s", f.log.String())
	}
	// Failures are counted per network, and so is the limit on the warning:
	// a neighbour in the same network gets no line of its own within the second.
	fail("[2001:db8:1:2::8]:50000")
	if n := strings.Count(f.log.String(), "authentication failed"); n != 1 {
		t.Fatalf("%d failure lines within a second for one network, want 1", n)
	}
	f.clock.advance(time.Second)
	fail("[2001:db8:1:2::8]:50000")
	if !strings.Contains(f.log.String(), "from=2001:db8:1:2::8\n") {
		t.Fatalf("the second warning does not name its address: %s", f.log.String())
	}
	if strings.Contains(f.log.String(), "/64") {
		t.Fatalf("a warning names a network instead of an address: %s", f.log.String())
	}
}
