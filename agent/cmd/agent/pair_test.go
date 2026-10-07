package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httputil"
	"net/url"
	"regexp"
	"strings"
	"testing"
	"time"

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

// pair runs the proof exchange with a typed code. The fingerprint in the
// proof is whatever this connection presented, which is what makes a relay
// useless.
func (p *phone) pair(code, name string) (status int, err error) {
	canonical, ok := pairing.Normalize(code)
	if !ok {
		return 0, fmt.Errorf("bad code %q", code)
	}
	var fp []byte
	if p.scheme == "https" {
		// Learn what the server presents before computing the proof.
		probe, err := p.do(http.MethodGet, "/healthz", nil)
		if err != nil {
			return 0, err
		}
		probe.Body.Close()
		fp = p.seen[:]
	}
	nonce := make([]byte, pairing.NonceLen)
	rand.Read(nonce)
	body, _ := json.Marshal(map[string]any{
		"v":     1,
		"nonce": base64.RawURLEncoding.EncodeToString(nonce),
		"proof": base64.RawURLEncoding.EncodeToString(pairing.PhoneProof(canonical, fp, nonce)),
		"name":  name,
	})
	resp, err := p.do(http.MethodPost, "/agent/v1/pair", body)
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
	agentNonce, _ := base64.RawURLEncoding.DecodeString(got.Nonce)
	proof, _ := base64.RawURLEncoding.DecodeString(got.Proof)
	if !bytes.Equal(proof, pairing.AgentProof(canonical, fp, nonce, agentNonce)) {
		return 0, errors.New("the server could not prove it holds the code")
	}
	if p.scheme == "https" {
		pinned := p.seen
		p.pin = &pinned
	}
	p.token = got.Token
	return http.StatusOK, nil
}

// pairWithLink is the QR path: the fingerprint comes from the link, and the
// phone refuses any other certificate from the first byte on.
func (p *phone) pairWithLink(link, name string) (int, error) {
	u, err := url.Parse(link)
	if err != nil {
		return 0, err
	}
	q := u.Query()
	if f := q.Get("f"); f != "" {
		raw, err := base64.RawURLEncoding.DecodeString(f)
		if err != nil || len(raw) != 32 {
			return 0, fmt.Errorf("bad fingerprint in the link: %q", f)
		}
		var pin tlsid.Fingerprint
		copy(pin[:], raw)
		p.pin = &pin
	}
	return p.pair(q.Get("c"), name)
}

func TestPairUseAndRevokeOverTLS(t *testing.T) {
	a := startAgent(t)

	// A read-only phone pairs by scanning.
	link, _, out, exit := a.startPair("--read-only")
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
	if code := <-exit; code != 0 {
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
	if code := <-exit2; code != 0 {
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
	canonical, _ := pairing.Normalize(code)
	for _, secret := range []string{viewer.token, full.token, code, canonical} {
		if strings.Contains(list, secret) || strings.Contains(a.log.String(), secret) {
			t.Fatal("a token or a code leaked into the output or the log")
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
	<-exit
	a.stop()
	if code, _, errOut := a.command("devices"); code != 1 || !strings.Contains(errOut, "not running") {
		t.Fatalf("devices against a stopped agent: %d %q", code, errOut)
	}

	// The same folder starts again on the same address: the phone is known.
	again := startAgent(t, "AGENT_DATA", a.env["AGENT_DATA"], "AGENT_LISTEN", a.addr)
	if got := p.status("GET", "/containers/json"); got != http.StatusOK {
		t.Fatalf("after a restart the paired phone gets %d", got)
	}
	again.stop()

	// A different agent takes over the address: the pin refuses it.
	startAgent(t, "AGENT_LISTEN", a.addr)
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
	if got := <-exit; got != 0 {
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
	if got := <-exit; got != 1 || !strings.Contains(out.String(), "pairing cancelled") {
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

func TestPairCommandLine(t *testing.T) {
	runCommandCases(t, []commandCase{
		{name: "help lists the pairing commands", args: []string{"help"}, code: 0, inStdout: "docker-mobile-agent pair"},
		{name: "devices without an agent", args: []string{"devices"}, code: 1, inStderr: "not running"},
		{name: "pair without an agent", args: []string{"pair"}, code: 1, inStderr: "not running"},
		{name: "revoke without an agent", args: []string{"revoke", "abcd1234"}, code: 1, inStderr: "not running"},
		{name: "revoke without an id", args: []string{"revoke"}, code: 1, inStderr: "give the id"},
		{name: "revoke with two ids", args: []string{"revoke", "a", "b"}, code: 1, inStderr: "give the id"},
		{name: "pair with a stray argument", args: []string{"pair", "now"}, code: 1, inStderr: `unexpected argument "now"`},
		{name: "pair with an unknown flag", args: []string{"pair", "--admin"}, code: 1, inStderr: "pair:"},
	})
}

func TestPairRejectsABadHost(t *testing.T) {
	a := startAgent(t)
	if code, _, errOut := a.command("pair", "--host", "https://x"); code != 1 || !strings.Contains(errOut, "without a scheme") {
		t.Fatalf("exit %d: %s", code, errOut)
	}
}
