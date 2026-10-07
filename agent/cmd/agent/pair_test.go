package main

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/admin"
	"github.com/retransmit/docker-mobile/agent/internal/pairing"
	"github.com/retransmit/docker-mobile/agent/internal/state"
	"github.com/retransmit/docker-mobile/agent/internal/tlsid"
)

var (
	linkInOutput = regexp.MustCompile(`dockermobile://pair\?\S+`)
	codeInOutput = regexp.MustCompile(`Code:\s+(\S+)`)
)

// startPair runs "pair" in the background and returns once it has printed
// its code and link.
func (a *agent) startPair(args ...string) (link, code string, out *syncBuf, exit <-chan int) {
	a.t.Helper()
	out = &syncBuf{}
	done := make(chan int, 1)
	go func() {
		done <- run(context.Background(), append([]string{"pair", "--no-qr"}, args...), a.getenv, out, out)
	}()
	waitFor(a.t, "the pairing code", func() bool { return strings.Contains(out.String(), "Waiting for the phone") })
	return linkInOutput.FindString(out.String()), codeInOutput.FindStringSubmatch(out.String())[1], out, done
}

// exited waits for a pair command that runs in the background to end and
// returns its exit code.
func exited(t *testing.T, exit <-chan int) int {
	t.Helper()
	select {
	case code := <-exit:
		return code
	case <-time.After(5 * time.Second):
		t.Fatal("the pair command did not end")
		return -1
	}
}

// pairTimeout is how long the phone gives one pairing attempt. An agent
// needs a few hundredths of a second to check a proof and store a device.
// Whoever holds the connection open instead of answering holds a proof to
// test guesses of the code against, and must not get to choose how long.
const pairTimeout = 5 * time.Second

// pair runs the proof exchange with a typed code.
func (p *phone) pair(code, name string) (status int, err error) {
	return p.pairWithin(pairTimeout, code, name)
}

// pairWithin is pair with the time the whole attempt may take.
//
// A proof is good for one certificate. It must therefore travel on a
// connection that presented that certificate and no other: a proof made for
// the agent's certificate and sent over a connection that someone else
// terminated is all that person needs to pair in the phone's place. This
// phone opens a connection for every request, so it first looks at what the
// server presents and then pins exactly that for the rest of the attempt.
// The connection that carries the proof then presents the same key or fails
// its handshake before anything is sent on it.
//
// Nothing is kept unless the answer proves that the server holds the code
// too. Whenever the attempt does not end that way the phone is left as it
// was: without a token, and with the pin it had before or none.
func (p *phone) pairWithin(limit time.Duration, code, name string) (status int, err error) {
	canonical, ok := pairing.Normalize(code)
	if !ok {
		return 0, fmt.Errorf("bad code %q", code)
	}
	ctx, cancel := context.WithTimeout(context.Background(), limit)
	defer cancel()

	before, paired := p.pin, false
	defer func() {
		if !paired {
			p.pin = before
		}
	}()
	var fp []byte
	if p.scheme == "https" {
		probe, err := p.doWithin(ctx, http.MethodGet, "/healthz", nil)
		if err != nil {
			return 0, err
		}
		probe.Body.Close()
		// A copy: every later handshake writes to p.seen, also one that the
		// pin then refuses.
		presented := p.seen
		p.pin = &presented
		fp = presented[:]
	}
	nonce := make([]byte, pairing.NonceLen)
	rand.Read(nonce)
	body, _ := json.Marshal(map[string]any{
		"v":     1,
		"nonce": base64.RawURLEncoding.EncodeToString(nonce),
		"proof": base64.RawURLEncoding.EncodeToString(pairing.PhoneProof(canonical, fp, nonce)),
		"name":  name,
	})
	resp, err := p.doWithin(ctx, http.MethodPost, "/agent/v1/pair", body)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return resp.StatusCode, nil
	}
	var got struct {
		Nonce, Proof, Token string
	}
	if err := json.NewDecoder(resp.Body).Decode(&got); err != nil {
		return 0, err
	}
	// The lengths come first: the proof is computed over the two nonces one
	// after the other, which says what it should only for nonces of the
	// length both sides agreed on.
	agentNonce, errNonce := base64.RawURLEncoding.DecodeString(got.Nonce)
	proof, errProof := base64.RawURLEncoding.DecodeString(got.Proof)
	if errNonce != nil || errProof != nil || len(agentNonce) != pairing.NonceLen || len(proof) != sha256.Size {
		return 0, errors.New("the server's answer is malformed: its nonce or its proof is not 32 bytes")
	}
	if !hmac.Equal(proof, pairing.AgentProof(canonical, fp, nonce, agentNonce)) {
		return 0, errors.New("the server could not prove it holds the code")
	}
	// Only now does the phone trust the certificate and keep the token.
	paired = true
	p.token = got.Token
	return http.StatusOK, nil
}

// pairWithLink is the QR path: the fingerprint comes from the link, and the
// phone refuses any other certificate from the first byte on. A pin from a
// link is kept only together with the pairing it was for.
func (p *phone) pairWithLink(link, name string) (int, error) {
	u, err := url.Parse(link)
	if err != nil {
		return 0, err
	}
	q := u.Query()
	before := p.pin
	if f := q.Get("f"); f != "" {
		raw, err := base64.RawURLEncoding.DecodeString(f)
		if err != nil || len(raw) != 32 {
			return 0, fmt.Errorf("bad fingerprint in the link: %q", f)
		}
		var pin tlsid.Fingerprint
		copy(pin[:], raw)
		p.pin = &pin
	}
	status, err := p.pair(q.Get("c"), name)
	if err != nil || status != http.StatusOK {
		p.pin = before
	}
	return status, err
}

func TestPairUseAndRevokeOverTLS(t *testing.T) {
	a := startAgent(t)

	// A read-only phone pairs by scanning.
	link, firstCode, out, exit := a.startPair("--read-only")
	port := a.addr[strings.LastIndex(a.addr, ":")+1:]
	for _, want := range []string{"h=127.0.0.1", "p=" + port, "n=test+agent", "f=" + a.fingerprint().String(), "c="} {
		if !strings.Contains(link, want) {
			t.Fatalf("the link lacks %s: %s", want, link)
		}
	}
	viewer := newPhone(t, "https", a.addr)
	if status, err := viewer.pairWithLink(link, "Pixel 8"); err != nil || status != http.StatusOK {
		t.Fatalf("pairing by link: %d, %v", status, err)
	}
	if code := exited(t, exit); code != 0 {
		t.Fatalf("pair exited %d: %s", code, out.String())
	}
	for _, want := range []string{"Paired: Pixel 8", "read-only", "Address:      127.0.0.1:" + port, "Fingerprint:  " + a.fingerprint().Display()} {
		if !strings.Contains(out.String(), want) {
			t.Fatalf("the pair output lacks %q:\n%s", want, out.String())
		}
	}
	if got := viewer.status("GET", "/v1.45/containers/json"); got != http.StatusOK {
		t.Fatalf("a read: %d, want 200", got)
	}
	if got := viewer.status("POST", "/v1.45/containers/x/start"); got != http.StatusForbidden {
		t.Fatalf("a write from a read-only phone: %d, want 403", got)
	}

	// A second phone pairs with the typed code, knowing no fingerprint.
	_, code, out2, exit2 := a.startPair("--name", "kitchen tablet")
	full := newPhone(t, "https", a.addr)
	if status, err := full.pair(code, "whatever the phone says"); err != nil || status != http.StatusOK {
		t.Fatalf("pairing by code: %d, %v", status, err)
	}
	if code := exited(t, exit2); code != 0 {
		t.Fatalf("pair exited %d: %s", code, out2.String())
	}
	if !strings.Contains(out2.String(), "Paired: kitchen tablet") || !strings.Contains(out2.String(), "full control") {
		t.Fatalf("pair output: %s", out2.String())
	}
	if *full.pin != a.fingerprint() {
		t.Fatal("the phone pinned something other than the agent's fingerprint")
	}
	if got := full.status("POST", "/containers/x/start"); got != http.StatusOK {
		t.Fatalf("a write from a full phone: %d, want 200", got)
	}

	// Both show up in the list, and nothing secret anywhere.
	_, list, _ := a.command("devices")
	for _, want := range []string{"Pixel 8", "read-only", "kitchen tablet", "full control"} {
		if !strings.Contains(list, want) {
			t.Fatalf("the devices output lacks %q:\n%s", want, list)
		}
	}
	secrets := []string{viewer.token, full.token}
	for _, shown := range []string{firstCode, code} {
		canonical, _ := pairing.Normalize(shown)
		secrets = append(secrets, shown, canonical)
	}
	for _, secret := range secrets {
		if strings.Contains(list, secret) || strings.Contains(a.log.String(), secret) {
			t.Fatal("a token or a code leaked into the devices output or the log")
		}
	}
	// The pair command shows its code. A device token never reaches it, so
	// nothing that looks like one may be in what it printed.
	for _, printed := range []string{out.String(), out2.String()} {
		if strings.Contains(printed, "dm1.") {
			t.Fatal("a device token is in the output of the pair command")
		}
	}

	// Revoking a phone ends its open stream and its access.
	stream, err := viewer.do("GET", "/events", nil)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Body.Close()
	if _, err := io.ReadFull(stream.Body, make([]byte, 1)); err != nil {
		t.Fatalf("the stream did not start: %v", err)
	}
	id := regexp.MustCompile(`(?m)^([0-9a-f]{8})\s+Pixel 8`).FindStringSubmatch(list)[1]
	exitCode, revokeOut, errOut := a.command("revoke", id)
	if exitCode != 0 || !strings.Contains(revokeOut, "Revoked Pixel 8") || !strings.Contains(revokeOut, "closed 1 open connection") {
		t.Fatalf("revoke: %d %q %q", exitCode, revokeOut, errOut)
	}
	ended := make(chan struct{})
	go func() {
		io.Copy(io.Discard, stream.Body)
		close(ended)
	}()
	select {
	case <-ended:
	case <-time.After(3 * time.Second):
		t.Fatal("the stream of the revoked phone stayed open")
	}
	if got := viewer.status("GET", "/containers/json"); got != http.StatusUnauthorized {
		t.Fatalf("a revoked phone: %d, want 401", got)
	}
	if got := full.status("GET", "/containers/json"); got != http.StatusOK {
		t.Fatalf("the other phone was affected: %d", got)
	}
	if exitCode, _, errOut := a.command("revoke", id); exitCode != 1 || !strings.Contains(errOut, "no device") {
		t.Fatalf("revoking twice: %d %q", exitCode, errOut)
	}
}

func TestSomeoneInTheMiddleCannotPair(t *testing.T) {
	a := startAgent(t)

	// The attacker terminates TLS with a certificate of their own and
	// passes everything on to the real agent.
	attackerDir, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	attackerCert, err := tlsid.LoadOrCreate(attackerDir, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	target, _ := url.Parse("https://" + a.addr)
	relay := httputil.NewSingleHostReverseProxy(target)
	// The attacker does not care who it talks to.
	relay.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	ln, err := tls.Listen("tcp", "127.0.0.1:0", tlsid.ServerConfig(attackerCert))
	if err != nil {
		t.Fatal(err)
	}
	relaySrv := &http.Server{Handler: relay}
	go relaySrv.Serve(ln)
	defer relaySrv.Close()

	_, code, _, _ := a.startPair()
	victim := newPhone(t, "https", ln.Addr().String())
	status, err := victim.pair(code, "Pixel 8")
	if err != nil {
		t.Fatalf("pairing through the relay: %v", err)
	}
	if status != http.StatusForbidden {
		t.Fatalf("the agent answered %d to a relayed proof, want 403", status)
	}
	if victim.token != "" || victim.pin != nil {
		t.Fatal("the phone trusted the attacker")
	}
	if _, list, _ := a.command("devices"); !strings.Contains(list, "No phone is paired") {
		t.Fatalf("a device was created through the relay:\n%s", list)
	}

	// Straight to the agent the same code still works: one wrong try does
	// not void it.
	direct := newPhone(t, "https", a.addr)
	if status, err := direct.pair(code, "Pixel 8"); err != nil || status != http.StatusOK {
		t.Fatalf("pairing directly afterwards: %d, %v", status, err)
	}
}

// strangerCert makes a certificate with a key of its own, as anyone can.
func strangerCert(t *testing.T) tls.Certificate {
	t.Helper()
	dir, err := state.Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	cert, err := tlsid.LoadOrCreate(dir, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return cert
}

// passFirst hands the first connection it accepts to pass and every later
// one to whoever accepts from it.
type passFirst struct {
	net.Listener
	once sync.Once
	pass func(net.Conn)
}

func (l *passFirst) Accept() (net.Conn, error) {
	for {
		conn, err := l.Listener.Accept()
		if err != nil {
			return nil, err
		}
		passed := false
		l.once.Do(func() {
			passed = true
			go l.pass(conn)
		})
		if !passed {
			return conn, nil
		}
	}
}

// tunnel joins conn to the server at addr and moves the bytes both ways
// until one side ends. It looks into nothing: whoever is on conn sees the
// certificate of the server at addr.
func tunnel(conn net.Conn, addr string) {
	defer conn.Close()
	upstream, err := net.Dial("tcp", addr)
	if err != nil {
		return
	}
	defer upstream.Close()
	ended := make(chan struct{}, 2)
	go func() { io.Copy(upstream, conn); ended <- struct{}{} }()
	go func() { io.Copy(conn, upstream); ended <- struct{}{} }()
	<-ended
}

func TestARelayThatOnlyTerminatesTheProofConnectionGetsNothing(t *testing.T) {
	a := startAgent(t)

	// The attacker lets the first connection through untouched, so a phone
	// that looks at the certificate there sees the agent's. Every later
	// connection it terminates with a certificate of its own and hands what
	// it reads to the agent: a proof made for the agent's certificate would
	// be accepted there, and the token in the answer would be the attacker's.
	target, _ := url.Parse("https://" + a.addr)
	forward := httputil.NewSingleHostReverseProxy(target)
	forward.Transport = &http.Transport{TLSClientConfig: &tls.Config{InsecureSkipVerify: true}}
	var reached syncBuf // what the phone sent on a connection the attacker terminated
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	relaySrv := &http.Server{
		Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			fmt.Fprintln(&reached, r.Method, r.URL.Path)
			forward.ServeHTTP(w, r)
		}),
		// A handshake the phone refuses is what this test is about.
		ErrorLog: log.New(io.Discard, "", 0),
	}
	split := &passFirst{Listener: ln, pass: func(conn net.Conn) { tunnel(conn, a.addr) }}
	go relaySrv.Serve(tls.NewListener(split, tlsid.ServerConfig(strangerCert(t))))
	defer relaySrv.Close()

	_, code, out, exit := a.startPair()
	victim := newPhone(t, "https", ln.Addr().String())
	if status, err := victim.pair(code, "Pixel 8"); err == nil || !strings.Contains(err.Error(), "server identity changed") {
		t.Errorf("status %d, err = %v, want the phone to refuse the connection that presents another certificate", status, err)
	}
	if victim.token != "" || victim.pin != nil {
		t.Error("the phone kept a token or a pin from the attempt through the relay")
	}
	if got := reached.String(); got != "" {
		t.Errorf("the phone sent this on a connection the attacker terminated:\n%s", got)
	}
	if strings.Contains(a.log.String(), "/agent/v1/pair") {
		t.Error("a pairing request reached the agent through the relay")
	}
	if _, list, _ := a.command("devices"); !strings.Contains(list, "No phone is paired") {
		t.Errorf("a device was created through the relay:\n%s", list)
	}

	// The pairing is still pending, and straight to the agent the code works.
	direct := newPhone(t, "https", a.addr)
	if status, err := direct.pair(code, "Pixel 8"); err != nil || status != http.StatusOK {
		t.Fatalf("pairing directly afterwards: %d, %v", status, err)
	}
	if got := exited(t, exit); got != 0 || !strings.Contains(out.String(), "Paired: Pixel 8") {
		t.Fatalf("the pair command ended with %d and without the phone that paired directly", got)
	}
}

// impostor is a server with a certificate of its own that answers a pairing
// request itself, with the nonce and the proof that answer returns for the
// phone's nonce and the fingerprint of the impostor's own certificate. It
// returns the address it listens on.
func impostor(t *testing.T, answer func(phoneNonce, fingerprint []byte) (nonce, proof []byte)) string {
	t.Helper()
	cert := strangerCert(t)
	fp, err := tlsid.FingerprintOf(cert)
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("POST /agent/v1/pair", func(w http.ResponseWriter, r *http.Request) {
		var req struct{ Nonce string }
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "malformed", http.StatusBadRequest)
			return
		}
		phoneNonce, _ := base64.RawURLEncoding.DecodeString(req.Nonce)
		nonce, proof := answer(phoneNonce, fp[:])
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(map[string]string{
			"nonce": base64.RawURLEncoding.EncodeToString(nonce),
			"proof": base64.RawURLEncoding.EncodeToString(proof),
			"token": "dm1.0badc0de." + strings.Repeat("A", 43),
		})
	})
	ln, err := tls.Listen("tcp", "127.0.0.1:0", tlsid.ServerConfig(cert))
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: mux, ErrorLog: log.New(io.Discard, "", 0)}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return ln.Addr().String()
}

// someCode is a pairing code that no agent has issued.
func someCode(t *testing.T) string {
	t.Helper()
	code, err := pairing.NewCode(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return code
}

func TestAPhoneRefusesAnAnswerItCannotVerify(t *testing.T) {
	// Whoever terminates the phone's connection can answer the pairing
	// request with anything. Without the code it cannot make the proof.
	addr := impostor(t, func(_, _ []byte) (nonce, proof []byte) {
		nonce, proof = make([]byte, pairing.NonceLen), make([]byte, sha256.Size)
		rand.Read(nonce)
		rand.Read(proof)
		return nonce, proof
	})
	p := newPhone(t, "https", addr)
	if status, err := p.pair(someCode(t), "Pixel 8"); err == nil || !strings.Contains(err.Error(), "could not prove it holds the code") {
		t.Fatalf("status %d, err = %v, want the phone to refuse an answer it cannot verify", status, err)
	}
	if p.token != "" || p.pin != nil {
		t.Fatal("the phone kept a token or a pin from an answer it could not verify")
	}
}

func TestAPhoneRefusesAnAgentNonceOrProofOfTheWrongLength(t *testing.T) {
	// The server here holds the code, so its proof is right for whatever
	// nonce it sends: all that is wrong with an answer is a length. The first
	// case shows that the same server is believed when the lengths are right.
	code := someCode(t)
	for _, c := range []struct {
		name     string
		nonceLen int
		proof    func(right []byte) []byte
		accepted bool
	}{
		{"the right lengths", pairing.NonceLen, func(right []byte) []byte { return right }, true},
		{"a nonce one byte short", pairing.NonceLen - 1, func(right []byte) []byte { return right }, false},
		{"a nonce one byte long", pairing.NonceLen + 1, func(right []byte) []byte { return right }, false},
		{"no nonce", 0, func(right []byte) []byte { return right }, false},
		{"a proof one byte short", pairing.NonceLen, func(right []byte) []byte { return right[:len(right)-1] }, false},
		{"a proof one byte long", pairing.NonceLen, func(right []byte) []byte { return append(right, 0) }, false},
	} {
		addr := impostor(t, func(phoneNonce, fingerprint []byte) (nonce, proof []byte) {
			nonce = make([]byte, c.nonceLen)
			rand.Read(nonce)
			return nonce, c.proof(pairing.AgentProof(code, fingerprint, phoneNonce, nonce))
		})
		p := newPhone(t, "https", addr)
		status, err := p.pair(code, "Pixel 8")
		if c.accepted {
			if err != nil || status != http.StatusOK || p.token == "" || p.pin == nil {
				t.Errorf("%s: the phone did not pair: %d, %v", c.name, status, err)
			}
			continue
		}
		if err == nil || !strings.Contains(err.Error(), "not 32 bytes") {
			t.Errorf("%s: status %d, err = %v, want the phone to refuse the answer for its form", c.name, status, err)
		}
		if p.token != "" || p.pin != nil {
			t.Errorf("%s: the phone kept a token or a pin", c.name)
		}
	}
}

func TestAPhoneDoesNotWaitForEverForTheAnswer(t *testing.T) {
	// A server that takes the pairing request and then says nothing, for as
	// long as the phone stays.
	arrived := make(chan struct{})
	mux := http.NewServeMux()
	mux.HandleFunc("GET /healthz", func(w http.ResponseWriter, _ *http.Request) { w.Write([]byte("ok")) })
	mux.HandleFunc("POST /agent/v1/pair", func(_ http.ResponseWriter, r *http.Request) {
		close(arrived)
		<-r.Context().Done()
	})
	ln, err := tls.Listen("tcp", "127.0.0.1:0", tlsid.ServerConfig(strangerCert(t)))
	if err != nil {
		t.Fatal(err)
	}
	srv := &http.Server{Handler: mux, ErrorLog: log.New(io.Discard, "", 0)}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })

	p := newPhone(t, "https", ln.Addr().String())
	code := someCode(t)
	ended := make(chan error, 1)
	go func() {
		// A shorter limit than a phone sets, so that the test is quick, and
		// still many times what it takes to get the request to the server.
		_, err := p.pairWithin(time.Second, code, "Pixel 8")
		ended <- err
	}()
	select {
	case err := <-ended:
		if !errors.Is(err, context.DeadlineExceeded) {
			t.Fatalf("err = %v, want the attempt to run out of time", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("the phone still waits for an answer")
	}
	select {
	case <-arrived:
	default:
		t.Fatal("the attempt ran out of time before its request was with the server")
	}
	if p.token != "" || p.pin != nil {
		t.Fatal("the phone kept a token or a pin from an attempt that ran out of time")
	}
}

func TestAScannedCodeNeverReachesAnotherCertificate(t *testing.T) {
	a := startAgent(t)
	link, _, _, _ := a.startPair()

	// Another agent, with another key, answers where the phone connects.
	other := startAgent(t)
	p := newPhone(t, "https", other.addr)
	if _, err := p.pairWithLink(link, "Pixel 8"); err == nil || !strings.Contains(err.Error(), "server identity changed") {
		t.Fatalf("err = %v, want the pin from the link to refuse the other certificate", err)
	}
	if strings.Contains(other.log.String(), "/agent/v1/pair") {
		t.Fatal("the pairing request was sent to the wrong server")
	}
}

func TestAPairedPhoneSurvivesARestartAndRefusesAnotherKey(t *testing.T) {
	a := startAgent(t)
	link, _, _, exit := a.startPair()
	p := newPhone(t, "https", a.addr)
	if _, err := p.pairWithLink(link, "Pixel 8"); err != nil {
		t.Fatal(err)
	}
	exited(t, exit)
	a.stop()
	if code, _, errOut := a.command("devices"); code != 1 || !strings.Contains(errOut, "not running") {
		t.Fatalf("devices against a stopped agent: %d %q", code, errOut)
	}

	// The same folder starts again: the agent is who it was and knows the
	// phone. It takes a port of its own, and the phone is told where: the
	// port the first agent gave up may be someone else's by now.
	again := startAgent(t, "AGENT_DATA", a.env["AGENT_DATA"])
	p.addr = again.addr
	if got := p.status("GET", "/containers/json"); got != http.StatusOK {
		t.Fatalf("after a restart the paired phone gets %d", got)
	}
	again.stop()

	// Where the phone looks for its agent, a different one answers: the pin
	// refuses it.
	other := startAgent(t)
	p.addr = other.addr
	if _, err := p.do("GET", "/containers/json", nil); err == nil || !strings.Contains(err.Error(), "server identity changed") {
		t.Fatalf("err = %v, want the pin to refuse the new certificate", err)
	}
}

func TestPairingBehindAProxy(t *testing.T) {
	a := startAgent(t, "AGENT_INSECURE_HTTP", "1", "AGENT_ADVERTISE", "https://docker.example.com")
	link, code, out, exit := a.startPair()
	if !strings.Contains(link, "s=https") || !strings.Contains(link, "h=docker.example.com") || !strings.Contains(link, "p=443") || strings.Contains(link, "f=") {
		t.Fatalf("link = %s", link)
	}
	if strings.Contains(out.String(), "Fingerprint:") || !strings.Contains(out.String(), "Address:      https://docker.example.com:443") {
		t.Fatalf("pair output:\n%s", out.String())
	}
	p := newPhone(t, "http", a.addr)
	if status, err := p.pair(code, "Pixel 8"); err != nil || status != http.StatusOK {
		t.Fatalf("pairing over plain HTTP: %d, %v", status, err)
	}
	if got := exited(t, exit); got != 0 {
		t.Fatalf("pair exited %d", got)
	}
	if got := p.status("GET", "/containers/json"); got != http.StatusOK {
		t.Fatalf("code = %d, want 200", got)
	}
}

func TestPairWithoutAnAdvertisedAddressSaysWhatToDo(t *testing.T) {
	a := startAgent(t, "AGENT_ADVERTISE", "")
	link, _, out, _ := a.startPair()
	if strings.Contains(link, "h=") || !strings.Contains(out.String(), "AGENT_ADVERTISE or --host") {
		t.Fatalf("link = %s\noutput:\n%s", link, out.String())
	}
	link, _, out, _ = a.startPair("--host", "my-server.lan:9443")
	if !strings.Contains(link, "h=my-server.lan") || !strings.Contains(link, "p=9443") || !strings.Contains(out.String(), "Address:      my-server.lan:9443") {
		t.Fatalf("link = %s\noutput:\n%s", link, out.String())
	}
}

func TestPairDrawsAQRCodeAndLeavingItCancelsTheCode(t *testing.T) {
	a := startAgent(t)
	out := &syncBuf{}
	ctx, cancel := context.WithCancel(context.Background())
	exit := make(chan int, 1)
	go func() { exit <- run(ctx, []string{"pair"}, a.getenv, out, out) }()
	waitFor(t, "the pair output", func() bool { return strings.Contains(out.String(), "Waiting for the phone") })
	if !strings.Contains(out.String(), "\u2588") || !strings.Contains(out.String(), "Scan this with the docker-mobile app") {
		t.Fatalf("no QR code in the output:\n%s", out.String())
	}
	code := codeInOutput.FindStringSubmatch(out.String())[1]

	cancel() // Ctrl-C
	if got := exited(t, exit); got != 1 || !strings.Contains(out.String(), "pairing cancelled") {
		t.Fatalf("exit %d: %s", got, out.String())
	}
	waitFor(t, "the agent to cancel the pairing", func() bool { return strings.Contains(a.log.String(), "outcome=cancelled") })
	p := newPhone(t, "https", a.addr)
	if status, err := p.pair(code, "x"); err != nil || status != http.StatusNotFound {
		t.Fatalf("the cancelled code: %d, %v, want 404", status, err)
	}
	if _, list, _ := a.command("devices"); !strings.Contains(list, "No phone is paired") {
		t.Fatalf("a device was created with a cancelled code: %s", list)
	}
}

func TestStoppingTheAgentEndsAPendingPairCommand(t *testing.T) {
	a := startAgent(t)
	_, code, out, exit := a.startPair()
	a.stop()
	select {
	case got := <-exit:
		if got != 1 || !strings.Contains(out.String(), "the agent stopped before the pairing ended") {
			t.Fatalf("exit %d: %s", got, out.String())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the pair command kept waiting for a stopped agent")
	}
	// The code died with the agent: a restart does not bring it back.
	again := startAgent(t, "AGENT_DATA", a.env["AGENT_DATA"])
	p := newPhone(t, "https", again.addr)
	if status, err := p.pair(code, "x"); err != nil || status != http.StatusNotFound {
		t.Fatalf("the old code after a restart: %d, %v, want 404", status, err)
	}
}

func TestRevokeSaysSoWhenThePhoneIsStillPaired(t *testing.T) {
	a := startAgent(t)
	link, _, _, exit := a.startPair()
	p := newPhone(t, "https", a.addr)
	if status, err := p.pairWithLink(link, "Pixel 8"); err != nil || status != http.StatusOK {
		t.Fatalf("pairing by link: %d, %v", status, err)
	}
	if got := exited(t, exit); got != 0 {
		t.Fatalf("pair exited %d", got)
	}
	_, list, _ := a.command("devices")
	found := regexp.MustCompile(`(?m)^([0-9a-f]{8})\s+Pixel 8`).FindStringSubmatch(list)
	if found == nil {
		t.Fatalf("the paired phone is not in the list:\n%s", list)
	}

	// A folder is in the way where the device list is written: from here on
	// the agent can store nothing.
	file := filepath.Join(a.env["AGENT_DATA"], "devices.json")
	if err := os.Remove(file); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(file, "in the way"), 0o700); err != nil {
		t.Fatal(err)
	}

	code, out, errOut := a.command("revoke", found[1])
	if code != 1 || out != "" || !strings.HasPrefix(errOut, "docker-mobile-agent: the device is still paired") || !strings.Contains(errOut, "the removal could not be stored") {
		t.Fatalf("revoke: exit %d, stdout %q, stderr %q", code, out, errOut)
	}
	if got := p.status("GET", "/containers/json"); got != http.StatusOK {
		t.Fatalf("the phone that is still paired gets %d, want 200", got)
	}
}

// scriptedAdmin stands in for an agent on the admin socket of a fresh state
// folder: it answers a pair command with what pair writes. It returns the
// environment that leads a command to it.
func scriptedAdmin(t *testing.T, pair http.HandlerFunc) func(string) string {
	t.Helper()
	// A short path, as for a real agent: a socket lives in it.
	dataDir, err := os.MkdirTemp("", "dma")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dataDir) })
	ln, err := net.Listen("unix", filepath.Join(dataDir, "admin.sock"))
	if err != nil {
		t.Fatal(err)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("POST /pair", pair)
	srv := &http.Server{Handler: mux}
	go srv.Serve(ln)
	t.Cleanup(func() { srv.Close() })
	return func(k string) string {
		if k == "AGENT_DATA" {
			return dataDir
		}
		return ""
	}
}

// eventLines is a pairing stream as the agent writes it: an event a line.
func eventLines(events ...admin.Event) []byte {
	var b bytes.Buffer
	enc := json.NewEncoder(&b)
	for _, e := range events {
		enc.Encode(e)
	}
	return b.Bytes()
}

// scriptedStart is the first event of a scripted pairing. Nothing in it is
// real.
var scriptedStart = admin.Event{
	Event:     admin.EventStarted,
	Code:      "0000-0000-0000",
	Link:      "dockermobile://pair?c=000000000000&v=1",
	Address:   "agent.example:8443",
	Role:      "full",
	ExpiresIn: 300,
}

// interrupted is an output that presses Ctrl-C the moment the command has
// printed its code and begun to wait: writing "Waiting for the phone" to it
// ends the command's context.
type interrupted struct {
	syncBuf
	interrupt context.CancelFunc
}

func (o *interrupted) Write(p []byte) (int, error) {
	n, err := o.syncBuf.Write(p)
	if bytes.Contains(p, []byte("Waiting for the phone")) {
		o.interrupt()
	}
	return n, err
}

func TestPairReportsHowThePairingEnded(t *testing.T) {
	pixel := &admin.DeviceInfo{ID: "0a1b2c3d", Name: "Pixel 8", Role: "readonly"}
	for _, c := range []struct {
		name     string
		end      admin.Event
		code     int
		inStdout string
		inStderr string
	}{
		{"paired", admin.Event{Event: "paired", Device: pixel}, 0, "Paired: Pixel 8 (id 0a1b2c3d, read-only)", ""},
		{"paired, without the device", admin.Event{Event: "paired"}, 1, "", `a phone was paired, but not which one: look at "docker-mobile-agent devices"`},
		{"expired", admin.Event{Event: "expired"}, 1, "", "the code expired before a phone used it; run pair again"},
		{"replaced", admin.Event{Event: "replaced"}, 1, "", "another pair command replaced this code"},
		{"voided", admin.Event{Event: "voided"}, 1, "", "too many wrong attempts: the code was voided; run pair again"},
		{"failed", admin.Event{Event: "failed", Error: "write devices.json: no space left on device"}, 1, "",
			"the phone proved the code but the agent could not store it: write devices.json: no space left on device"},
		{"an event the command does not know", admin.Event{Event: "exploded"}, 1, "", `pairing ended as "exploded"`},
	} {
		getenv := scriptedAdmin(t, func(w http.ResponseWriter, _ *http.Request) {
			w.Write(eventLines(scriptedStart, c.end))
		})
		var out, errOut bytes.Buffer
		code := run(context.Background(), []string{"pair", "--no-qr"}, getenv, &out, &errOut)
		if code != c.code {
			t.Errorf("%s: exit %d, want %d (stderr: %s)", c.name, code, c.code, errOut.String())
		}
		if c.inStdout != "" && !strings.Contains(out.String(), c.inStdout) {
			t.Errorf("%s: stdout lacks %q: %s", c.name, c.inStdout, out.String())
		}
		if c.inStderr != "" && !strings.Contains(errOut.String(), c.inStderr) {
			t.Errorf("%s: stderr lacks %q: %s", c.name, c.inStderr, errOut.String())
		}
		if c.code == 0 && errOut.Len() != 0 {
			t.Errorf("%s: a pairing that worked wrote to stderr: %s", c.name, errOut.String())
		}
		if c.code != 0 && strings.Contains(out.String(), "Paired:") {
			t.Errorf("%s: stdout says a phone was paired: %s", c.name, out.String())
		}
	}
}

func TestAPairingThatEndedIsReportedThoughTheCommandWasInterrupted(t *testing.T) {
	// The whole pairing, its good end included, is in the agent's answer
	// before the command has printed the code, and the command is interrupted
	// while it prints: when it reads on, its context is over and the outcome
	// is there to be read. Both events go out in one write, so that the
	// command holds the second when it is interrupted over the first.
	pixel := &admin.DeviceInfo{ID: "0a1b2c3d", Name: "Pixel 8", Role: "full"}
	getenv := scriptedAdmin(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Write(eventLines(scriptedStart, admin.Event{Event: "paired", Device: pixel}))
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := &interrupted{interrupt: cancel}
	var errOut bytes.Buffer
	code := run(ctx, []string{"pair", "--no-qr"}, getenv, out, &errOut)
	if ctx.Err() == nil {
		t.Fatal("the command was not interrupted")
	}
	if code != 0 || !strings.Contains(out.String(), "Paired: Pixel 8 (id 0a1b2c3d, full control)") || errOut.Len() != 0 {
		t.Fatalf("exit %d\nstdout:\n%s\nstderr:\n%s", code, out.String(), errOut.String())
	}
}

func TestAnInterruptedPairClaimsOnlyWhatItKnows(t *testing.T) {
	// The agent has sent the code and waits for a phone that does not come.
	getenv := scriptedAdmin(t, func(w http.ResponseWriter, r *http.Request) {
		w.Write(eventLines(scriptedStart))
		w.(http.Flusher).Flush()
		<-r.Context().Done()
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	out := &interrupted{interrupt: cancel}
	var errOut bytes.Buffer
	code := run(ctx, []string{"pair", "--no-qr"}, getenv, out, &errOut)
	want := `pairing cancelled; the code no longer works. If a phone used it in the same moment it is paired: check with "docker-mobile-agent devices"`
	if code != 1 || !strings.Contains(errOut.String(), want) || strings.Contains(out.String(), "Paired:") {
		t.Fatalf("exit %d\nstdout:\n%s\nstderr:\n%s", code, out.String(), errOut.String())
	}
}

func TestAPairThatLosesTheAgentClaimsOnlyWhatItKnows(t *testing.T) {
	// The stream ends after the code and before any outcome, as it does when
	// the agent stops.
	getenv := scriptedAdmin(t, func(w http.ResponseWriter, _ *http.Request) {
		w.Write(eventLines(scriptedStart))
	})
	var out, errOut bytes.Buffer
	code := run(context.Background(), []string{"pair", "--no-qr"}, getenv, &out, &errOut)
	want := `the agent stopped before the pairing ended; the code no longer works. If a phone used it in the same moment it is paired, and still is when the agent runs again: check then with "docker-mobile-agent devices"`
	if code != 1 || !strings.Contains(errOut.String(), want) || strings.Contains(out.String(), "Paired:") {
		t.Fatalf("exit %d\nstdout:\n%s\nstderr:\n%s", code, out.String(), errOut.String())
	}
}

func TestPairCommandLine(t *testing.T) {
	// The commands that look for an agent get a state folder with a short
	// path: a longer one is refused for its length before anything is looked
	// for, and the temporary folder of a test can be that long.
	empty, err := os.MkdirTemp("", "dma")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(empty) })
	noAgent := []string{"AGENT_DATA", empty}
	runCommandCases(t, []commandCase{
		{name: "help lists the pairing commands", args: []string{"help"}, code: 0, inStdout: "docker-mobile-agent pair"},
		{name: "devices without an agent", args: []string{"devices"}, env: noAgent, code: 1, inStderr: "not running"},
		{name: "pair without an agent", args: []string{"pair"}, env: noAgent, code: 1, inStderr: "not running"},
		{name: "revoke without an agent", args: []string{"revoke", "abcd1234"}, env: noAgent, code: 1, inStderr: "not running"},
		{name: "revoke without an id", args: []string{"revoke"}, code: 1, inStderr: "give the id"},
		{name: "revoke with two ids", args: []string{"revoke", "a", "b"}, code: 1, inStderr: "give the id"},
		{name: "pair with a stray argument", args: []string{"pair", "now"}, code: 1, inStderr: `pair: unexpected argument "now"`},
		{name: "pair with an unknown flag", args: []string{"pair", "--admin"}, code: 1,
			stderrIs: "docker-mobile-agent: pair: flag provided but not defined: -admin (see: docker-mobile-agent pair --help)\n"},
		{name: "devices with a stray argument", args: []string{"devices", "extra"}, code: 1, inStderr: `devices: unexpected argument "extra"`},
		{name: "revoke with an unknown flag", args: []string{"revoke", "--all"}, code: 1,
			stderrIs: "docker-mobile-agent: revoke: flag provided but not defined: -all (see: docker-mobile-agent revoke --help)\n"},
	})
}

func TestPairRejectsABadHost(t *testing.T) {
	a := startAgent(t)
	if code, _, errOut := a.command("pair", "--host", "https://x"); code != 1 || !strings.Contains(errOut, "without a scheme") {
		t.Fatalf("exit %d: %s", code, errOut)
	}
}
