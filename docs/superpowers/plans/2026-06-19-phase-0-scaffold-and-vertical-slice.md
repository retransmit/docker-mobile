# docker-mobile Phase 0 — Scaffold & Vertical Slice — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up the monorepo and ship one complete, tested vertical slice — a Go agent that token-authenticates and transparently proxies the Docker Engine API, and a Flutter app that connects to it and lists containers.

**Architecture:** Monorepo with `/agent` (Go) and `/app` (Flutter). The agent is a thin authenticated reverse-proxy in front of the Docker socket. The app speaks the **raw Docker Engine API** through a single `DockerApiClient` that sits on a pluggable `Transport`; Phase 0 implements only the `AgentTransport` (HTTPS/HTTP + bearer token). This proves the end-to-end path before breadth is added in Phase 1.

**Tech Stack:** Go 1.22 (stdlib `net/http`, `net/http/httputil`), Flutter (stable) / Dart 3, `flutter_riverpod` for state, `package:http` for networking, GitHub Actions CI.

## Global Constraints

- **Engine API target:** Docker Engine API **v1.45+** (Docker 25+); negotiate the effective version at runtime via `GET /version` (Phase 1 wires negotiation — Phase 0 calls unversioned paths, which hit the daemon's latest).
- **Single API client:** all Docker calls go through one `DockerApiClient`; transports are interchangeable behind the `Transport` interface. Never bypass it.
- **Phase 0 transport scope:** **agent transport only.** Direct TCP+TLS and SSH transports are Phase 1 (the `Transport` interface is designed to accommodate them, but only `AgentTransport` is implemented now).
- **Phase 0 agent docker-host scope:** the agent dials Docker over **unix socket** and **tcp** only. Windows named-pipe (`npipe`) and hijacked-stream/WebSocket bridging (exec/attach) are Phase 1. These are scoped-out, not stubbed — do not leave placeholder code for them.
- **Security:** the agent token is a root-grade secret. Compare it in constant time. Never log the token, request bodies, or any secret. Cert/key/token files are already blocked by `.gitignore`.
- **Git:** repo is local/private (no remote). Commit author is already configured (`0xLennox07` / `parththale02@gmail.com`). **Commit messages must NOT include a `Co-Authored-By` trailer.**
- **Discipline:** TDD (test first, watch it fail, minimal impl, watch it pass), DRY, YAGNI, frequent commits — one commit per task minimum.

---

## File Structure

```
docker-mobile/
├── .github/workflows/ci.yml         # CI: go test + flutter test
├── README.md                        # repo overview + run instructions
├── agent/                           # Go module: the companion agent
│   ├── go.mod                       # module github.com/0xLennox07/docker-mobile/agent
│   ├── cmd/agent/main.go            # entrypoint: load config, build proxy, serve
│   ├── internal/config/config.go    # Config struct + Load() from env
│   ├── internal/config/config_test.go
│   ├── internal/dockerhost/dialer.go      # DialContextFor(host) → dial fn + base URL
│   ├── internal/dockerhost/dialer_test.go
│   ├── internal/auth/auth.go        # RequireToken middleware (constant-time)
│   ├── internal/auth/auth_test.go
│   ├── internal/proxy/proxy.go      # New(dockerHost) → *DockerProxy (http.Handler)
│   ├── internal/proxy/proxy_test.go
│   ├── internal/server/server.go    # Handler(cfg) wires auth + proxy + /healthz
│   ├── internal/server/server_test.go
│   └── smoke_test.go                # trivial test proving `go test ./...` runs
└── app/                             # Flutter app
    ├── pubspec.yaml
    ├── lib/
    │   ├── main.dart                # ProviderScope + first screen
    │   └── src/
    │       ├── api/
    │       │   ├── docker_api_client.dart      # DockerApiClient + DockerApiException
    │       │   └── models/container.dart       # Container model + fromJson
    │       ├── transport/
    │       │   ├── transport.dart              # abstract Transport
    │       │   └── agent_transport.dart        # AgentTransport (token + base URI)
    │       ├── state/providers.dart            # Riverpod providers
    │       └── ui/
    │           ├── connection_screen.dart      # enter host/port/token → connect
    │           └── containers_screen.dart      # list containers
    └── test/
        ├── api/models/container_test.dart
        ├── api/docker_api_client_test.dart
        ├── transport/agent_transport_test.dart
        └── ui/containers_screen_test.dart
```

**Responsibilities (one job each):**
- `config` — read/validate agent configuration from the environment.
- `dockerhost` — turn a `DOCKER_HOST` string into a dial function + base URL (transport-agnostic socket plumbing).
- `auth` — bearer-token gate, nothing else.
- `proxy` — forward an authenticated HTTP request to the daemon and stream the response back.
- `server` — compose auth + proxy + a health endpoint into one `http.Handler`.
- App `transport` — move bytes to/from a daemon (Phase 0: via the agent).
- App `api` — model the Engine API and expose typed calls.
- App `state`/`ui` — Riverpod wiring and minimal screens.

---

## Task 1: Monorepo scaffold, toolchains, CI

**Files:**
- Create: `README.md`
- Create: `agent/go.mod`
- Create: `agent/smoke_test.go`
- Create: `app/` (via `flutter create`)
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: nothing (first task).
- Produces: a valid Go module `github.com/0xLennox07/docker-mobile/agent` and a Flutter project rooted at `app/`, both with a passing test; a CI workflow that runs both test suites.

- [ ] **Step 1: Verify toolchains are present**

Run:
```bash
go version
flutter --version
```
Expected: Go ≥ 1.22 and a Flutter stable release print their versions. If either is missing, install it (https://go.dev/dl, https://docs.flutter.dev/get-started/install) before continuing.

- [ ] **Step 2: Initialize the Go module and a smoke test**

Run:
```bash
cd agent && go mod init github.com/0xLennox07/docker-mobile/agent && cd ..
```

Create `agent/smoke_test.go`:
```go
package agent

import "testing"

// TestSmoke proves the module compiles and `go test ./...` runs in CI.
func TestSmoke(t *testing.T) {
	if 1+1 != 2 {
		t.Fatal("arithmetic is broken")
	}
}
```

- [ ] **Step 3: Run the Go smoke test (expect PASS)**

Run: `cd agent && go test ./... && cd ..`
Expected: `ok  github.com/0xLennox07/docker-mobile/agent` — PASS.

- [ ] **Step 4: Scaffold the Flutter app**

Run:
```bash
flutter create --project-name docker_mobile --platforms=android,ios app
```
Expected: `app/` is created with the default counter app and a passing `app/test/widget_test.dart`.

- [ ] **Step 5: Run the Flutter smoke test (expect PASS)**

Run: `cd app && flutter test && cd ..`
Expected: `All tests passed!`

- [ ] **Step 6: Add CI workflow**

Create `.github/workflows/ci.yml`:
```yaml
name: ci
on: [push, pull_request]
jobs:
  agent:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: agent
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: '1.22'
      - run: go vet ./...
      - run: go test ./...
  app:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: app
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          channel: stable
      - run: flutter pub get
      - run: flutter analyze
      - run: flutter test
```

- [ ] **Step 7: Add README**

Create `README.md`:
```markdown
# docker-mobile

Open-source, self-hostable mobile app (Flutter, iOS + Android) for full control of
Docker from your phone. See `docs/superpowers/specs/` for the design.

## Layout
- `agent/` — Go companion agent: authenticated transparent proxy to the Docker socket.
- `app/`   — Flutter app.

## Run the agent (dev)
```
cd agent
AGENT_TOKEN=dev-secret DOCKER_HOST=unix:///var/run/docker.sock go run ./cmd/agent
```
The agent listens on `:8080` by default. On Docker Desktop you can instead point it at
the exposed TCP API, e.g. `DOCKER_HOST=tcp://127.0.0.1:2375`.

## Run the app (dev)
```
cd app
flutter run
```
Enter the agent's host, port, and token on the connection screen.

## Test
```
cd agent && go test ./...
cd app && flutter test
```
```

- [ ] **Step 8: Commit**

```bash
git add README.md agent app .github
git commit -m "chore: scaffold monorepo (go agent + flutter app) and CI"
```

---

## Task 2: Agent configuration loader

**Files:**
- Create: `agent/internal/config/config.go`
- Test: `agent/internal/config/config_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `type Config struct { ListenAddr string; Token string; DockerHost string }`
  - `func Load(getenv func(string) string) (Config, error)` — reads `AGENT_LISTEN` (default `:8080`), `AGENT_TOKEN` (required, else error), `DOCKER_HOST` (default `unix:///var/run/docker.sock`). Takes `getenv` for testability (pass `os.Getenv` in `main`).

- [ ] **Step 1: Write the failing test**

Create `agent/internal/config/config_test.go`:
```go
package config

import "testing"

func env(m map[string]string) func(string) string {
	return func(k string) string { return m[k] }
}

func TestLoadDefaults(t *testing.T) {
	cfg, err := Load(env(map[string]string{"AGENT_TOKEN": "secret"}))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.ListenAddr != ":8080" {
		t.Errorf("ListenAddr = %q, want :8080", cfg.ListenAddr)
	}
	if cfg.DockerHost != "unix:///var/run/docker.sock" {
		t.Errorf("DockerHost = %q, want unix:///var/run/docker.sock", cfg.DockerHost)
	}
	if cfg.Token != "secret" {
		t.Errorf("Token = %q, want secret", cfg.Token)
	}
}

func TestLoadOverrides(t *testing.T) {
	cfg, err := Load(env(map[string]string{
		"AGENT_TOKEN":  "t",
		"AGENT_LISTEN": ":9000",
		"DOCKER_HOST":  "tcp://127.0.0.1:2375",
	}))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.ListenAddr != ":9000" || cfg.DockerHost != "tcp://127.0.0.1:2375" {
		t.Errorf("overrides not applied: %+v", cfg)
	}
}

func TestLoadRequiresToken(t *testing.T) {
	if _, err := Load(env(map[string]string{})); err == nil {
		t.Fatal("expected error when AGENT_TOKEN is missing")
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd agent && go test ./internal/config/ -v`
Expected: FAIL — `Load` undefined.

- [ ] **Step 3: Write the minimal implementation**

Create `agent/internal/config/config.go`:
```go
// Package config loads the agent's runtime configuration from the environment.
package config

import "errors"

type Config struct {
	ListenAddr string
	Token      string
	DockerHost string
}

// Load builds a Config from getenv. AGENT_TOKEN is required.
func Load(getenv func(string) string) (Config, error) {
	cfg := Config{
		ListenAddr: getenv("AGENT_LISTEN"),
		Token:      getenv("AGENT_TOKEN"),
		DockerHost: getenv("DOCKER_HOST"),
	}
	if cfg.ListenAddr == "" {
		cfg.ListenAddr = ":8080"
	}
	if cfg.DockerHost == "" {
		cfg.DockerHost = "unix:///var/run/docker.sock"
	}
	if cfg.Token == "" {
		return Config{}, errors.New("AGENT_TOKEN is required")
	}
	return cfg, nil
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd agent && go test ./internal/config/ -v`
Expected: PASS (all three tests).

- [ ] **Step 5: Commit**

```bash
git add agent/internal/config
git commit -m "feat(agent): config loader from environment"
```

---

## Task 3: Agent Docker-host dialer (unix + tcp)

**Files:**
- Create: `agent/internal/dockerhost/dialer.go`
- Test: `agent/internal/dockerhost/dialer_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `type DialFunc = func(ctx context.Context, network, addr string) (net.Conn, error)`
  - `func DialContextFor(host string) (dial DialFunc, baseURL string, err error)` — for `unix://<path>` returns a dialer to that socket and `baseURL == "http://docker"`; for `tcp://<host:port>` returns a tcp dialer and `baseURL == "http://<host:port>"`. Any other scheme → error. `baseURL` is the origin the proxy rewrites requests to.

- [ ] **Step 1: Write the failing test**

Create `agent/internal/dockerhost/dialer_test.go`:
```go
package dockerhost

import (
	"context"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDialContextForTCP(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("pong"))
	}))
	defer srv.Close()

	dial, base, err := DialContextFor("tcp://" + srv.Listener.Addr().String())
	if err != nil {
		t.Fatalf("DialContextFor: %v", err)
	}
	if base != "http://"+srv.Listener.Addr().String() {
		t.Errorf("base = %q", base)
	}
	// The dial function must reach the test server regardless of the addr passed.
	conn, err := dial(context.Background(), "tcp", "ignored:0")
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	_ = conn.Close()
}

func TestDialContextForUnixBaseURL(t *testing.T) {
	dial, base, err := DialContextFor("unix:///var/run/docker.sock")
	if err != nil {
		t.Fatalf("DialContextFor: %v", err)
	}
	if base != "http://docker" {
		t.Errorf("base = %q, want http://docker", base)
	}
	if dial == nil {
		t.Fatal("dial is nil")
	}
	_ = net.Conn(nil)
}

func TestDialContextForUnknownScheme(t *testing.T) {
	if _, _, err := DialContextFor("ssh://host"); err == nil {
		t.Fatal("expected error for unsupported scheme")
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd agent && go test ./internal/dockerhost/ -v`
Expected: FAIL — `DialContextFor` undefined.

- [ ] **Step 3: Write the minimal implementation**

Create `agent/internal/dockerhost/dialer.go`:
```go
// Package dockerhost converts a DOCKER_HOST string into a net dialer and the
// base origin URL the agent's reverse proxy should target.
package dockerhost

import (
	"context"
	"fmt"
	"net"
	"net/url"
	"time"
)

type DialFunc = func(ctx context.Context, network, addr string) (net.Conn, error)

func DialContextFor(host string) (DialFunc, string, error) {
	u, err := url.Parse(host)
	if err != nil {
		return nil, "", fmt.Errorf("parse DOCKER_HOST %q: %w", host, err)
	}
	switch u.Scheme {
	case "unix":
		socket := u.Path
		dial := func(ctx context.Context, _, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 10 * time.Second}
			return d.DialContext(ctx, "unix", socket)
		}
		return dial, "http://docker", nil
	case "tcp":
		addr := u.Host
		dial := func(ctx context.Context, _, _ string) (net.Conn, error) {
			d := net.Dialer{Timeout: 10 * time.Second}
			return d.DialContext(ctx, "tcp", addr)
		}
		return dial, "http://" + addr, nil
	default:
		return nil, "", fmt.Errorf("unsupported DOCKER_HOST scheme %q (Phase 0 supports unix and tcp)", u.Scheme)
	}
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd agent && go test ./internal/dockerhost/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add agent/internal/dockerhost
git commit -m "feat(agent): docker-host dialer for unix and tcp"
```

---

## Task 4: Agent token-auth middleware

**Files:**
- Create: `agent/internal/auth/auth.go`
- Test: `agent/internal/auth/auth_test.go`

**Interfaces:**
- Consumes: nothing.
- Produces: `func RequireToken(token string, next http.Handler) http.Handler` — passes the request through only if the `Authorization` header equals `Bearer <token>` (constant-time compare); otherwise responds `401` with body `unauthorized\n` and does not call `next`.

- [ ] **Step 1: Write the failing test**

Create `agent/internal/auth/auth_test.go`:
```go
package auth

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func okHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
}

func TestRequireTokenAllows(t *testing.T) {
	h := RequireToken("secret", okHandler())
	req := httptest.NewRequest(http.MethodGet, "/containers/json", nil)
	req.Header.Set("Authorization", "Bearer secret")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
}

func TestRequireTokenRejectsMissing(t *testing.T) {
	h := RequireToken("secret", okHandler())
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("code = %d, want 401", rec.Code)
	}
}

func TestRequireTokenRejectsWrong(t *testing.T) {
	h := RequireToken("secret", okHandler())
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer nope")
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("code = %d, want 401", rec.Code)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd agent && go test ./internal/auth/ -v`
Expected: FAIL — `RequireToken` undefined.

- [ ] **Step 3: Write the minimal implementation**

Create `agent/internal/auth/auth.go`:
```go
// Package auth provides the agent's bearer-token gate.
package auth

import (
	"crypto/subtle"
	"net/http"
)

func RequireToken(token string, next http.Handler) http.Handler {
	want := []byte("Bearer " + token)
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got := []byte(r.Header.Get("Authorization"))
		if subtle.ConstantTimeCompare(got, want) != 1 {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		next.ServeHTTP(w, r)
	})
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd agent && go test ./internal/auth/ -v`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add agent/internal/auth
git commit -m "feat(agent): constant-time bearer-token auth middleware"
```

---

## Task 5: Agent transparent reverse proxy

**Files:**
- Create: `agent/internal/proxy/proxy.go`
- Test: `agent/internal/proxy/proxy_test.go`

**Interfaces:**
- Consumes: `dockerhost.DialContextFor` (Task 3).
- Produces: `func New(dockerHost string) (http.Handler, error)` — returns an `http.Handler` that forwards every incoming request to the Docker daemon at `dockerHost` and streams the response back unchanged (status, headers, body).

- [ ] **Step 1: Write the failing test**

Create `agent/internal/proxy/proxy_test.go`:
```go
package proxy

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// fakeDaemon emulates the bits of the Docker API this test needs.
func fakeDaemon() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/_ping", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Api-Version", "1.45")
		w.Write([]byte("OK"))
	})
	mux.HandleFunc("/containers/json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode([]map[string]any{
			{"Id": "abc123", "Names": []string{"/web"}, "Image": "nginx", "State": "running", "Status": "Up 2 hours"},
		})
	})
	return httptest.NewServer(mux)
}

func TestProxyForwardsJSON(t *testing.T) {
	daemon := fakeDaemon()
	defer daemon.Close()

	h, err := New("tcp://" + daemon.Listener.Addr().String())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/containers/json?all=true", nil)
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	body, _ := io.ReadAll(rec.Body)
	var got []map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode: %v (body=%s)", err, body)
	}
	if len(got) != 1 || got[0]["Id"] != "abc123" {
		t.Fatalf("unexpected body: %s", body)
	}
}

func TestProxyForwardsPing(t *testing.T) {
	daemon := fakeDaemon()
	defer daemon.Close()
	h, _ := New("tcp://" + daemon.Listener.Addr().String())
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/_ping", nil))
	if rec.Code != http.StatusOK || rec.Header().Get("Api-Version") != "1.45" {
		t.Fatalf("ping not proxied: code=%d apiver=%q", rec.Code, rec.Header().Get("Api-Version"))
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd agent && go test ./internal/proxy/ -v`
Expected: FAIL — `New` undefined.

- [ ] **Step 3: Write the minimal implementation**

Create `agent/internal/proxy/proxy.go`:
```go
// Package proxy forwards Docker Engine API requests to the daemon socket and
// streams responses back unchanged.
package proxy

import (
	"net/http"
	"net/http/httputil"
	"net/url"

	"github.com/0xLennox07/docker-mobile/agent/internal/dockerhost"
)

func New(dockerHost string) (http.Handler, error) {
	dial, base, err := dockerhost.DialContextFor(dockerHost)
	if err != nil {
		return nil, err
	}
	target, err := url.Parse(base)
	if err != nil {
		return nil, err
	}
	rp := httputil.NewSingleHostReverseProxy(target)
	rp.Transport = &http.Transport{DialContext: dial}
	// NewSingleHostReverseProxy rewrites scheme+host to target; ensure the
	// outbound Host header matches so the daemon accepts it.
	origDirector := rp.Director
	rp.Director = func(r *http.Request) {
		origDirector(r)
		r.Host = target.Host
	}
	return rp, nil
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd agent && go test ./internal/proxy/ -v`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add agent/internal/proxy
git commit -m "feat(agent): transparent reverse proxy to docker daemon"
```

---

## Task 6: Agent server wiring + entrypoint

**Files:**
- Create: `agent/internal/server/server.go`
- Test: `agent/internal/server/server_test.go`
- Create: `agent/cmd/agent/main.go`

**Interfaces:**
- Consumes: `config.Config` (Task 2), `auth.RequireToken` (Task 4), `proxy.New` (Task 5).
- Produces: `func Handler(cfg config.Config) (http.Handler, error)` — returns the full agent handler: `GET /healthz` is unauthenticated and returns `200 ok`; every other path requires the bearer token and is proxied to Docker.

- [ ] **Step 1: Write the failing test**

Create `agent/internal/server/server_test.go`:
```go
package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/0xLennox07/docker-mobile/agent/internal/config"
)

func fakeDaemon() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode([]map[string]any{{"Id": "x"}})
	}))
}

func newHandler(t *testing.T, daemon *httptest.Server) http.Handler {
	t.Helper()
	h, err := Handler(config.Config{
		ListenAddr: ":0",
		Token:      "secret",
		DockerHost: "tcp://" + daemon.Listener.Addr().String(),
	})
	if err != nil {
		t.Fatalf("Handler: %v", err)
	}
	return h
}

func TestHealthzNoAuth(t *testing.T) {
	d := fakeDaemon()
	defer d.Close()
	h := newHandler(t, d)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("healthz code = %d, want 200", rec.Code)
	}
}

func TestProxiedPathRequiresAuth(t *testing.T) {
	d := fakeDaemon()
	defer d.Close()
	h := newHandler(t, d)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/containers/json", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated proxy code = %d, want 401", rec.Code)
	}
}

func TestProxiedPathWithAuth(t *testing.T) {
	d := fakeDaemon()
	defer d.Close()
	h := newHandler(t, d)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/containers/json", nil)
	req.Header.Set("Authorization", "Bearer secret")
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("authenticated proxy code = %d, want 200", rec.Code)
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd agent && go test ./internal/server/ -v`
Expected: FAIL — `Handler` undefined.

- [ ] **Step 3: Write the minimal implementation**

Create `agent/internal/server/server.go`:
```go
// Package server composes the agent's HTTP handler: an unauthenticated health
// check plus the token-gated transparent Docker proxy.
package server

import (
	"net/http"

	"github.com/0xLennox07/docker-mobile/agent/internal/auth"
	"github.com/0xLennox07/docker-mobile/agent/internal/config"
	"github.com/0xLennox07/docker-mobile/agent/internal/proxy"
)

func Handler(cfg config.Config) (http.Handler, error) {
	dockerProxy, err := proxy.New(cfg.DockerHost)
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	mux.Handle("/", auth.RequireToken(cfg.Token, dockerProxy))
	return mux, nil
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd agent && go test ./internal/server/ -v`
Expected: PASS (all three).

- [ ] **Step 5: Write the entrypoint**

Create `agent/cmd/agent/main.go`:
```go
// Command agent runs the docker-mobile companion agent.
package main

import (
	"log"
	"net/http"
	"os"

	"github.com/0xLennox07/docker-mobile/agent/internal/config"
	"github.com/0xLennox07/docker-mobile/agent/internal/server"
)

func main() {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	h, err := server.Handler(cfg)
	if err != nil {
		log.Fatalf("server: %v", err)
	}
	log.Printf("docker-mobile-agent listening on %s (docker host: %s)", cfg.ListenAddr, cfg.DockerHost)
	if err := http.ListenAndServe(cfg.ListenAddr, h); err != nil {
		log.Fatalf("listen: %v", err)
	}
}
```

- [ ] **Step 6: Verify the whole agent builds and tests pass**

Run: `cd agent && go vet ./... && go test ./... && go build ./cmd/agent && cd ..`
Expected: vet clean, all tests PASS, binary builds.

- [ ] **Step 7: Commit**

```bash
git add agent/internal/server agent/cmd
git commit -m "feat(agent): wire health + auth + proxy into server and entrypoint"
```

---

## Task 7: App — Container model

**Files:**
- Create: `app/lib/src/api/models/container.dart`
- Test: `app/test/api/models/container_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `class Container` with fields `String id`, `List<String> names`, `String image`, `String state`, `String status`, and `factory Container.fromJson(Map<String, dynamic> json)` mapping the Engine API `/containers/json` element keys (`Id`, `Names`, `Image`, `State`, `Status`).

- [ ] **Step 1: Write the failing test**

Create `app/test/api/models/container_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container.dart';

void main() {
  test('parses a /containers/json element', () {
    final json = {
      'Id': 'abc123',
      'Names': ['/web'],
      'Image': 'nginx:latest',
      'State': 'running',
      'Status': 'Up 2 hours',
    };
    final c = Container.fromJson(json);
    expect(c.id, 'abc123');
    expect(c.names, ['/web']);
    expect(c.image, 'nginx:latest');
    expect(c.state, 'running');
    expect(c.status, 'Up 2 hours');
  });

  test('tolerates missing optional fields', () {
    final c = Container.fromJson({'Id': 'x', 'Names': <String>[], 'Image': 'busybox'});
    expect(c.state, '');
    expect(c.status, '');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd app && flutter test test/api/models/container_test.dart`
Expected: FAIL — target of URI doesn't exist / `Container` undefined.

- [ ] **Step 3: Write the minimal implementation**

Create `app/lib/src/api/models/container.dart`:
```dart
/// A Docker container as returned by `GET /containers/json`.
class Container {
  final String id;
  final List<String> names;
  final String image;
  final String state;
  final String status;

  const Container({
    required this.id,
    required this.names,
    required this.image,
    required this.state,
    required this.status,
  });

  factory Container.fromJson(Map<String, dynamic> json) {
    return Container(
      id: json['Id'] as String,
      names: (json['Names'] as List?)?.cast<String>() ?? const [],
      image: json['Image'] as String? ?? '',
      state: json['State'] as String? ?? '',
      status: json['Status'] as String? ?? '',
    );
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/api/models/container_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/models/container.dart app/test/api/models/container_test.dart
git commit -m "feat(app): Container model with fromJson"
```

---

## Task 8: App — Transport interface + AgentTransport

**Files:**
- Create: `app/lib/src/transport/transport.dart`
- Create: `app/lib/src/transport/agent_transport.dart`
- Test: `app/test/transport/agent_transport_test.dart`
- Modify: `app/pubspec.yaml` (add `http`, `flutter_riverpod`)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `abstract class Transport { Future<http.Response> get(String path, {Map<String, String>? query}); }`
  - `class AgentTransport implements Transport` with constructor `AgentTransport({required Uri baseUri, required String token, http.Client? client})`. Its `get` issues `GET {baseUri + path}?{query}` with header `Authorization: Bearer <token>`.

- [ ] **Step 1: Add dependencies**

Edit `app/pubspec.yaml` — under `dependencies:` add:
```yaml
  http: ^1.2.0
  flutter_riverpod: ^2.5.1
```
Run: `cd app && flutter pub get`
Expected: resolves successfully.

- [ ] **Step 2: Write the failing test**

Create `app/test/transport/agent_transport_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';

void main() {
  test('sends bearer token and builds the right URL', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response('[]', 200);
    });
    final t = AgentTransport(
      baseUri: Uri.parse('http://10.0.0.5:8080'),
      token: 'secret',
      client: mock,
    );

    final resp = await t.get('/containers/json', query: {'all': 'true'});

    expect(resp.statusCode, 200);
    expect(captured.headers['Authorization'], 'Bearer secret');
    expect(captured.url.path, '/containers/json');
    expect(captured.url.queryParameters['all'], 'true');
    expect(captured.url.host, '10.0.0.5');
    expect(captured.url.port, 8080);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd app && flutter test test/transport/agent_transport_test.dart`
Expected: FAIL — `AgentTransport` undefined.

- [ ] **Step 4: Write the interface**

Create `app/lib/src/transport/transport.dart`:
```dart
import 'package:http/http.dart' as http;

/// Moves Docker Engine API requests to a daemon. Phase 0 implements only
/// [AgentTransport]; TCP+TLS and SSH transports arrive in Phase 1.
abstract class Transport {
  Future<http.Response> get(String path, {Map<String, String>? query});
}
```

- [ ] **Step 5: Write the AgentTransport implementation**

Create `app/lib/src/transport/agent_transport.dart`:
```dart
import 'package:http/http.dart' as http;

import 'transport.dart';

/// Talks to the docker-mobile agent over HTTP(S) with a bearer token.
class AgentTransport implements Transport {
  final Uri baseUri;
  final String token;
  final http.Client _client;

  AgentTransport({
    required this.baseUri,
    required this.token,
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    return _client.get(uri, headers: {'Authorization': 'Bearer $token'});
  }
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `cd app && flutter test test/transport/agent_transport_test.dart`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/src/transport app/test/transport
git commit -m "feat(app): Transport interface and AgentTransport"
```

---

## Task 9: App — DockerApiClient.listContainers

**Files:**
- Create: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/docker_api_client_test.dart`

**Interfaces:**
- Consumes: `Transport` (Task 8), `Container` (Task 7).
- Produces:
  - `class DockerApiException implements Exception { final int statusCode; final String body; }`
  - `class DockerApiClient { DockerApiClient(this.transport); final Transport transport; Future<List<Container>> listContainers({bool all = true}); }` — calls `transport.get('/containers/json', query: {'all': all})`, throws `DockerApiException` on non-200, else decodes the JSON array into `List<Container>`.

- [ ] **Step 1: Write the failing test**

Create `app/test/api/docker_api_client_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _FakeTransport implements Transport {
  final http.Response response;
  String? lastPath;
  Map<String, String>? lastQuery;
  _FakeTransport(this.response);

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    lastPath = path;
    lastQuery = query;
    return response;
  }
}

void main() {
  test('listContainers decodes the array', () async {
    final t = _FakeTransport(http.Response(
      '[{"Id":"a","Names":["/web"],"Image":"nginx","State":"running","Status":"Up"}]',
      200,
    ));
    final client = DockerApiClient(t);

    final containers = await client.listContainers();

    expect(t.lastPath, '/containers/json');
    expect(t.lastQuery, {'all': 'true'});
    expect(containers, hasLength(1));
    expect(containers.first.id, 'a');
    expect(containers.first.image, 'nginx');
  });

  test('listContainers throws DockerApiException on non-200', () async {
    final t = _FakeTransport(http.Response('boom', 500));
    final client = DockerApiClient(t);
    expect(
      () => client.listContainers(),
      throwsA(isA<DockerApiException>().having((e) => e.statusCode, 'statusCode', 500)),
    );
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd app && flutter test test/api/docker_api_client_test.dart`
Expected: FAIL — `DockerApiClient` undefined.

- [ ] **Step 3: Write the minimal implementation**

Create `app/lib/src/api/docker_api_client.dart`:
```dart
import 'dart:convert';

import '../transport/transport.dart';
import 'models/container.dart';

class DockerApiException implements Exception {
  final int statusCode;
  final String body;
  const DockerApiException(this.statusCode, this.body);

  @override
  String toString() => 'DockerApiException($statusCode): $body';
}

/// The single Docker Engine API client used across all transports.
class DockerApiClient {
  final Transport transport;
  const DockerApiClient(this.transport);

  Future<List<Container>> listContainers({bool all = true}) async {
    final resp = await transport.get('/containers/json', query: {'all': all.toString()});
    if (resp.statusCode != 200) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    final decoded = jsonDecode(resp.body) as List<dynamic>;
    return decoded
        .map((e) => Container.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd app && flutter test test/api/docker_api_client_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/docker_api_client.dart app/test/api/docker_api_client_test.dart
git commit -m "feat(app): DockerApiClient.listContainers"
```

---

## Task 10: App — Riverpod providers, UI, and end-to-end wiring

**Files:**
- Create: `app/lib/src/state/providers.dart`
- Create: `app/lib/src/ui/containers_screen.dart`
- Create: `app/lib/src/ui/connection_screen.dart`
- Modify: `app/lib/main.dart`
- Test: `app/test/ui/containers_screen_test.dart`
- Modify: `app/test/widget_test.dart` (replace default counter test)

**Interfaces:**
- Consumes: `DockerApiClient` (Task 9), `AgentTransport` (Task 8), `Container` (Task 7).
- Produces:
  - `final transportProvider = StateProvider<Transport?>((ref) => null);`
  - `final dockerClientProvider = Provider<DockerApiClient?>((ref) {...});`
  - `final containersProvider = FutureProvider<List<Container>>((ref) async {...});`
  - `class ContainersScreen extends ConsumerWidget` rendering the async list (loading / error / data with each container's name + image + state).
  - `class ConnectionScreen extends ConsumerStatefulWidget` collecting host/port/token and setting `transportProvider`.

- [ ] **Step 1: Write the failing widget test**

Create `app/test/ui/containers_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/api/models/container.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/containers_screen.dart';

void main() {
  testWidgets('renders container names from the provider', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          containersProvider.overrideWith((ref) async => const [
                Container(id: 'a', names: ['/web'], image: 'nginx', state: 'running', status: 'Up'),
                Container(id: 'b', names: ['/db'], image: 'postgres', state: 'exited', status: 'Exited'),
              ]),
        ],
        child: const MaterialApp(home: ContainersScreen()),
      ),
    );
    // Let the FutureProvider resolve.
    await tester.pumpAndSettle();

    expect(find.text('/web'), findsOneWidget);
    expect(find.text('/db'), findsOneWidget);
    expect(find.textContaining('nginx'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd app && flutter test test/ui/containers_screen_test.dart`
Expected: FAIL — `providers.dart` / `ContainersScreen` undefined.

- [ ] **Step 3: Write the providers**

Create `app/lib/src/state/providers.dart`:
```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container.dart';
import '../transport/transport.dart';

/// The active transport, set once the user connects. Null = not connected.
final transportProvider = StateProvider<Transport?>((ref) => null);

/// The single Docker client, derived from the active transport.
final dockerClientProvider = Provider<DockerApiClient?>((ref) {
  final transport = ref.watch(transportProvider);
  return transport == null ? null : DockerApiClient(transport);
});

/// The container list for the current connection.
final containersProvider = FutureProvider<List<Container>>((ref) async {
  final client = ref.watch(dockerClientProvider);
  if (client == null) {
    throw StateError('Not connected');
  }
  return client.listContainers();
});
```

- [ ] **Step 4: Write the ContainersScreen**

Create `app/lib/src/ui/containers_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

class ContainersScreen extends ConsumerWidget {
  const ContainersScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final containers = ref.watch(containersProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Containers'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => ref.invalidate(containersProvider),
          ),
        ],
      ),
      body: containers.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => ListView.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final c = list[i];
            final name = c.names.isNotEmpty ? c.names.first : c.id;
            return ListTile(
              leading: Icon(
                c.state == 'running' ? Icons.play_circle : Icons.stop_circle,
                color: c.state == 'running' ? Colors.green : Colors.grey,
              ),
              title: Text(name),
              subtitle: Text('${c.image} · ${c.status}'),
            );
          },
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: Run the widget test to verify it passes**

Run: `cd app && flutter test test/ui/containers_screen_test.dart`
Expected: PASS.

- [ ] **Step 6: Write the ConnectionScreen**

Create `app/lib/src/ui/connection_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../transport/agent_transport.dart';
import 'containers_screen.dart';

class ConnectionScreen extends ConsumerStatefulWidget {
  const ConnectionScreen({super.key});

  @override
  ConsumerState<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends ConsumerState<ConnectionScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8080');
  final _token = TextEditingController();
  bool _useTls = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  void _connect() {
    final scheme = _useTls ? 'https' : 'http';
    final baseUri = Uri.parse('$scheme://${_host.text}:${_port.text}');
    ref.read(transportProvider.notifier).state =
        AgentTransport(baseUri: baseUri, token: _token.text);
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ContainersScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect to agent')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host / IP')),
            TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port')),
            TextField(
              controller: _token,
              decoration: const InputDecoration(labelText: 'Token'),
              obscureText: true,
            ),
            SwitchListTile(
              title: const Text('Use TLS (https)'),
              value: _useTls,
              onChanged: (v) => setState(() => _useTls = v),
            ),
            const SizedBox(height: 16),
            FilledButton(onPressed: _connect, child: const Text('Connect')),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 7: Wire main.dart**

Replace `app/lib/main.dart` with:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/ui/connection_screen.dart';

void main() {
  runApp(const ProviderScope(child: DockerMobileApp()));
}

class DockerMobileApp extends StatelessWidget {
  const DockerMobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'docker-mobile',
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: const ConnectionScreen(),
    );
  }
}
```

- [ ] **Step 8: Replace the default widget test so it matches the new app**

Replace `app/test/widget_test.dart` with:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/main.dart';

void main() {
  testWidgets('app boots to the connection screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: DockerMobileApp()));
    expect(find.text('Connect to agent'), findsOneWidget);
    expect(find.text('Connect'), findsWidgets);
  });
}
```

- [ ] **Step 9: Run the full app suite + analyzer**

Run: `cd app && flutter analyze && flutter test && cd ..`
Expected: analyzer clean, `All tests passed!`

- [ ] **Step 10: Commit**

```bash
git add app/lib app/test
git commit -m "feat(app): providers, connection + containers screens, end-to-end wiring"
```

---

## Task 11: End-to-end manual smoke test + docs

**Files:**
- Create: `docs/MANUAL-SMOKE-TEST.md`

**Interfaces:**
- Consumes: the built agent (Task 6) and app (Task 10).
- Produces: a documented, repeatable manual verification that the slice works against a real Docker daemon.

- [ ] **Step 1: Start a real Docker daemon reachable by the agent**

If on Linux with Docker: the default `unix:///var/run/docker.sock` works.
If on Windows/macOS Docker Desktop: enable "Expose daemon on tcp://localhost:2375 without TLS" in Docker Desktop settings (dev only), or run the agent inside a container that mounts the socket.

- [ ] **Step 2: Run the agent against the real daemon**

Run (Linux):
```bash
cd agent && AGENT_TOKEN=dev-secret DOCKER_HOST=unix:///var/run/docker.sock go run ./cmd/agent
```
Run (Docker Desktop TCP):
```bash
cd agent && AGENT_TOKEN=dev-secret DOCKER_HOST=tcp://127.0.0.1:2375 go run ./cmd/agent
```
Expected log: `docker-mobile-agent listening on :8080 ...`

- [ ] **Step 3: Verify the agent proxies (curl)**

Run:
```bash
curl -s http://127.0.0.1:8080/healthz
curl -s -H "Authorization: Bearer dev-secret" http://127.0.0.1:8080/containers/json?all=true
```
Expected: `ok`, then a JSON array of your containers. Without the header you should get `401 unauthorized`.

- [ ] **Step 4: Run the app and connect**

Run: `cd app && flutter run` (choose an emulator/device). On the connection screen enter the host (use `10.0.2.2` from an Android emulator to reach the host machine; `localhost` on iOS simulator), port `8080`, token `dev-secret`, TLS off, and tap Connect.
Expected: the Containers screen lists the same containers `curl` returned; the refresh button reloads them.

- [ ] **Step 5: Capture the procedure**

Create `docs/MANUAL-SMOKE-TEST.md` documenting Steps 1–4 above (commands, the emulator host-IP note, and expected results) so it can be re-run each release.

- [ ] **Step 6: Commit**

```bash
git add docs/MANUAL-SMOKE-TEST.md
git commit -m "docs: phase 0 end-to-end manual smoke test"
```

---

## Self-Review

**1. Spec coverage (Phase 0 scope):**
- Monorepo `/app` + `/agent` → Task 1. ✓
- `/shared` API model + codegen → intentionally deferred; Phase 0 hand-writes the `Container` model (Task 7). Codegen revisited in Phase 1 (spec §11 open question). Documented as scope, not a gap.
- CI → Task 1. ✓
- `Transport` interface + `AgentTransport` → Task 8. ✓
- `DockerApiClient` (single client) → Task 9. ✓
- Agent skeleton (auth + transparent proxy) → Tasks 2–6. ✓
- First real call: connect → list containers → Tasks 9–11. ✓
- TCP+TLS / SSH transports, npipe, exec/attach WS bridging, push notifications → **Phase 1+**, explicitly out of Phase 0 scope per Global Constraints. ✓

**2. Placeholder scan:** No `TBD`/`TODO`/"add error handling"/"similar to Task N". Every code step shows complete code; every run step shows the command + expected result. ✓

**3. Type consistency:** `Transport.get(String path, {Map<String, String>? query})` is defined in Task 8 and consumed identically in Tasks 9 and the fakes in Task 9/10. `Container.fromJson` (Task 7) is used in Task 9. `DockerApiClient(this.transport)` + `listContainers({bool all = true})` (Task 9) match the providers in Task 10. Agent: `config.Config{ListenAddr,Token,DockerHost}` (Task 2) used in Tasks 5/6; `dockerhost.DialContextFor` (Task 3) used in Task 5 (`proxy.New`); `auth.RequireToken` (Task 4) and `proxy.New` (Task 5) used in Task 6 (`server.Handler`). Module path `github.com/0xLennox07/docker-mobile/agent` consistent across imports. ✓

---

## Execution Handoff

Phase 0 ends with a working, fully-tested vertical slice. **Phase 1** (next plan) builds breadth on this foundation: full container/image/network/volume/system lifecycle, live log streaming + search, the exec terminal (incl. the agent's WebSocket⇄hijacked-exec bridge and stdcopy demux), then the TCP+TLS and SSH transports.
