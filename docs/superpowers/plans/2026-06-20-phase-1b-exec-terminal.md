# Phase 1B — Interactive Exec Terminal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An interactive shell in a container from the phone — the agent bridges a WebSocket to Docker's hijacked exec stream, and the app renders it in an xterm terminal with resize.

**Architecture:** App creates an exec via the existing proxy (`Transport.post`), then opens a WebSocket to the agent's new `/exec/{id}/ws` endpoint; the agent hand-rolls the `POST /exec/{id}/start` hijack and bridges raw bytes ⇄ WebSocket. The app wires an `ExecChannel` to an xterm `Terminal`; resize is a separate proxied `POST /exec/{id}/resize`.

**Tech Stack:** Go 1.23 + `github.com/gorilla/websocket`; Flutter 3.44 / Dart 3.12 + `web_socket_channel`, `xterm`.

## Global Constraints

- **Exec is agent-only in 1B.** `Transport.execAttach`/`post` are implemented by `AgentTransport`; the (not-yet-existing) TCP+TLS/SSH transports defer to sub-project D. Do not add direct-hijack client code here.
- **Default shell command:** `['/bin/sh', '-c', "if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi"]`. A custom command from the UI runs as `['/bin/sh', '-c', <input>]`.
- **WS framing:** terminal bytes travel as **binary** WebSocket messages; the agent treats text and binary as raw bytes. The agent sends a TTY (un-multiplexed) stream — no stdcopy demux on exec.
- **Auth:** the `/exec/{id}/ws` endpoint sits behind the existing token middleware; the Flutter client sends `Authorization: Bearer <token>` on the WS handshake (native `IOWebSocketChannel` supports handshake headers).
- **Cancellation:** leaving the exec screen closes the `ExecChannel` (WS) → the agent closes the hijacked conn; the bridge tears down both directions when either ends.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix flutter commands with `export PATH="/c/src/flutter/bin:$PATH"`. Go module `github.com/0xLennox07/docker-mobile/agent` (go 1.23).
- **Discipline:** TDD, DRY, YAGNI, frequent commits, commit messages with NO `Co-Authored-By` trailer. Repo local/private on a feature branch.

---

## File Structure

```
agent/go.mod                                  # + github.com/gorilla/websocket
agent/internal/exec/bridge.go                 # startExecHijack + NewHandler + bridge
agent/internal/exec/bridge_test.go
agent/internal/server/server.go               # route GET /exec/{id}/ws

app/lib/src/transport/transport.dart          # + post, execAttach, ExecChannel
app/lib/src/transport/agent_transport.dart    # + post, execAttach (IOWebSocketChannel)
app/lib/src/api/models/exec_inspect.dart      # ExecInspect
app/lib/src/api/docker_api_client.dart        # + createExec/attachExec/resizeExec/inspectExec
app/lib/src/state/exec_session_controller.dart# ExecSessionController + ExecStatus
app/lib/src/ui/exec_screen.dart               # ExecScreen
app/lib/src/ui/containers_screen.dart         # trailing exec icon
app/pubspec.yaml                              # + web_socket_channel, xterm

app/test/transport/agent_transport_exec_test.dart
app/test/api/models/exec_inspect_test.dart
app/test/api/docker_api_client_exec_test.dart
app/test/state/exec_session_controller_test.dart
app/test/ui/exec_screen_test.dart
# plus: add post()+execAttach() stubs to existing Transport fakes (Task 3)
```

---

## Task 1: Agent — exec-start hijack

**Files:**
- Create: `agent/internal/exec/bridge.go`
- Test: `agent/internal/exec/bridge_test.go`

**Interfaces:**
- Consumes: `dockerhost.DialFunc` / `dockerhost.DialContextFor`.
- Produces: `func startExecHijack(ctx context.Context, dial dockerhost.DialFunc, execID string) (net.Conn, error)` — dials the daemon, sends `POST /exec/{execID}/start` with upgrade headers + `{"Detach":false,"Tty":true}`, parses the response status line, and returns a `net.Conn` whose reads include any post-header buffered bytes; errors on a status other than 101/200.

- [ ] **Step 1: Write the failing test**

Create `agent/internal/exec/bridge_test.go`:
```go
package exec

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
)

// fakeExecStart serves one connection: records the request, replies with
// `response`, then (optionally) keeps the connection for streaming.
func fakeExecStart(t *testing.T, response string, gotReq *string, hold chan struct{}) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		br := bufio.NewReader(conn)
		req, err := http.ReadRequest(br)
		if err != nil {
			return
		}
		body, _ := io.ReadAll(req.Body)
		*gotReq = req.Method + " " + req.URL.Path + "|" + string(body)
		io.WriteString(conn, response)
		if hold != nil {
			<-hold
		}
	}()
	return ln.Addr().String()
}

func dialTo(addr string) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, _, _ string) (net.Conn, error) { return net.Dial("tcp", addr) }
}

func TestStartExecHijackReturnsRawStream(t *testing.T) {
	var got string
	addr := fakeExecStart(t, "HTTP/1.1 101 UPGRADED\r\n\r\nHELLO", &got, nil)

	conn, err := startExecHijack(context.Background(), dialTo(addr), "abc")
	if err != nil {
		t.Fatalf("startExecHijack: %v", err)
	}
	defer conn.Close()

	if !strings.Contains(got, "POST /exec/abc/start") {
		t.Errorf("request line = %q", got)
	}
	if !strings.Contains(got, `"Tty":true`) {
		t.Errorf("request body = %q", got)
	}
	buf := make([]byte, 5)
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatalf("read stream: %v", err)
	}
	if string(buf) != "HELLO" {
		t.Errorf("stream = %q, want HELLO", buf)
	}
}

func TestStartExecHijackRejectsErrorStatus(t *testing.T) {
	var got string
	addr := fakeExecStart(t, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n", &got, nil)
	if _, err := startExecHijack(context.Background(), dialTo(addr), "abc"); err == nil {
		t.Fatal("expected error on 500 status")
	}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd agent && go test ./internal/exec/ -run TestStartExecHijack -v`
Expected: FAIL — `startExecHijack` undefined (package won't compile).

- [ ] **Step 3: Write the implementation**

Create `agent/internal/exec/bridge.go`:
```go
// Package exec bridges Docker's hijacked exec stream to a WebSocket.
package exec

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"

	"github.com/0xLennox07/docker-mobile/agent/internal/dockerhost"
)

// startExecHijack dials the Docker daemon and starts the given exec with a TTY,
// hijacking the connection into a raw bidirectional stream.
func startExecHijack(ctx context.Context, dial dockerhost.DialFunc, execID string) (net.Conn, error) {
	conn, err := dial(ctx, "tcp", "docker")
	if err != nil {
		return nil, fmt.Errorf("dial docker: %w", err)
	}
	const body = `{"Detach":false,"Tty":true}`
	req := "POST /exec/" + execID + "/start HTTP/1.1\r\n" +
		"Host: docker\r\n" +
		"Content-Type: application/json\r\n" +
		"Connection: Upgrade\r\n" +
		"Upgrade: tcp\r\n" +
		"Content-Length: " + strconv.Itoa(len(body)) + "\r\n" +
		"\r\n" + body
	if _, err := io.WriteString(conn, req); err != nil {
		conn.Close()
		return nil, fmt.Errorf("write exec start: %w", err)
	}

	br := bufio.NewReader(conn)
	statusLine, err := br.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("read status line: %w", err)
	}
	fields := strings.SplitN(strings.TrimSpace(statusLine), " ", 3)
	if len(fields) < 2 {
		conn.Close()
		return nil, fmt.Errorf("malformed status line: %q", statusLine)
	}
	code, err := strconv.Atoi(fields[1])
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("bad status code %q", fields[1])
	}
	if code != 101 && code != 200 {
		conn.Close()
		return nil, fmt.Errorf("exec start: unexpected status %d", code)
	}
	// Drain the remaining response headers up to the blank line.
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			conn.Close()
			return nil, fmt.Errorf("read headers: %w", err)
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	// br may already hold stream bytes read past the headers.
	return &bufferedConn{Conn: conn, r: br}, nil
}

// bufferedConn makes reads drain any bytes the header parser buffered first.
type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.r.Read(p) }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd agent && go test ./internal/exec/ -v`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add agent/internal/exec/bridge.go agent/internal/exec/bridge_test.go
git commit -m "feat(agent): hand-rolled exec-start hijack"
```

---

## Task 2: Agent — WebSocket bridge handler + route

**Files:**
- Modify: `agent/internal/exec/bridge.go` (+ `NewHandler`, `bridge`)
- Modify: `agent/internal/exec/bridge_test.go` (+ bridge/auth test)
- Modify: `agent/internal/server/server.go` (route)
- Modify: `agent/go.mod` (gorilla/websocket)

**Interfaces:**
- Consumes: `startExecHijack` (Task 1), `dockerhost.DialContextFor`, `auth.RequireToken`.
- Produces: `func NewHandler(dockerHost string) (http.Handler, error)` — a handler that upgrades to a WebSocket, hijacks the exec named by the `{id}` path value, and bridges WS⇄conn bidirectionally. `server.Handler` routes `GET /exec/{id}/ws` to it behind token auth.

- [ ] **Step 1: Add the dependency**

Run:
```bash
cd agent && go get github.com/gorilla/websocket@latest && cd ..
```
Expected: `go.mod`/`go.sum` updated.

- [ ] **Step 2: Write the failing test**

Append to `agent/internal/exec/bridge_test.go`:
```go
// (add these imports to the existing import block:
//   "net/http/httptest", "time", "github.com/gorilla/websocket",
//   "github.com/0xLennox07/docker-mobile/agent/internal/auth")

func TestExecBridgeEchoesBothDirections(t *testing.T) {
	// Fake daemon: parse the exec-start request, reply 101, then echo stdin->stdout.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		br := bufio.NewReader(conn)
		req, err := http.ReadRequest(br)
		if err != nil {
			return
		}
		io.ReadAll(req.Body)
		io.WriteString(conn, "HTTP/1.1 101 UPGRADED\r\n\r\n")
		io.Copy(conn, br) // echo stdin back as stdout
	}()

	h, err := NewHandler("tcp://" + ln.Addr().String())
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	mux := http.NewServeMux()
	mux.Handle("GET /exec/{id}/ws", auth.RequireToken("secret", h))
	srv := httptest.NewServer(mux)
	defer srv.Close()
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/exec/abc/ws"

	// Without a token -> rejected at the auth layer.
	if _, resp, err := websocket.DefaultDialer.Dial(wsURL, nil); err == nil {
		t.Fatal("expected auth rejection")
	} else if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("want 401, got %v", resp)
	}

	// With a token -> connect and echo.
	c, _, err := websocket.DefaultDialer.Dial(wsURL, http.Header{"Authorization": {"Bearer secret"}})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()
	if err := c.WriteMessage(websocket.BinaryMessage, []byte("hello")); err != nil {
		t.Fatalf("write: %v", err)
	}
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, data, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(data) != "hello" {
		t.Fatalf("echo = %q, want hello", data)
	}
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `cd agent && go test ./internal/exec/ -run TestExecBridge -v`
Expected: FAIL — `NewHandler` undefined.

- [ ] **Step 4: Add `NewHandler` + `bridge`**

Append to `agent/internal/exec/bridge.go` (and add `"net/http"`, `"time"`, `"github.com/gorilla/websocket"` to its imports):
```go
// NewHandler returns a handler that upgrades the request to a WebSocket and
// bridges it to a hijacked exec stream on the daemon at dockerHost.
func NewHandler(dockerHost string) (http.Handler, error) {
	dial, _, err := dockerhost.DialContextFor(dockerHost)
	if err != nil {
		return nil, err
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		execID := r.PathValue("id")
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return // Upgrade already wrote an error response
		}
		defer ws.Close()
		conn, err := startExecHijack(r.Context(), dial, execID)
		if err != nil {
			ws.WriteControl(
				websocket.CloseMessage,
				websocket.FormatCloseMessage(websocket.CloseInternalServerErr, "exec start failed"),
				time.Now().Add(time.Second),
			)
			return
		}
		defer conn.Close()
		bridge(ws, conn)
	}), nil
}

// bridge copies bytes between the WebSocket (stdin) and the conn (stdout) until
// either side ends, then tears down both directions.
func bridge(ws *websocket.Conn, conn net.Conn) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 32*1024)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				if werr := ws.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		ws.Close() // unblock the reader below
	}()
	for {
		_, data, err := ws.ReadMessage()
		if err != nil {
			break
		}
		if _, werr := conn.Write(data); werr != nil {
			break
		}
	}
	conn.Close()
	<-done
}
```

- [ ] **Step 5: Route it in the server**

In `agent/internal/server/server.go`, add the import `"github.com/0xLennox07/docker-mobile/agent/internal/exec"`, then in `Handler`, after building `dockerProxy` and before `mux.Handle("/", ...)`:
```go
	execHandler, err := exec.NewHandler(cfg.DockerHost)
	if err != nil {
		return nil, err
	}
	mux.Handle("GET /exec/{id}/ws", auth.RequireToken(cfg.Token, execHandler))
```

- [ ] **Step 6: Run vet + the full agent suite**

Run: `cd agent && go vet ./... && go test -count=1 ./... && go build ./cmd/agent && cd ..`
Expected: vet clean, all packages PASS (incl. the echo + auth bridge test), binary builds.

- [ ] **Step 7: Commit**

```bash
git add agent/internal/exec agent/internal/server agent/go.mod agent/go.sum
git commit -m "feat(agent): WebSocket bridge for interactive exec (/exec/{id}/ws)"
```

---

## Task 3: App — Transport.post + ExecChannel + execAttach

**Files:**
- Modify: `app/lib/src/transport/transport.dart`
- Modify: `app/lib/src/transport/agent_transport.dart`
- Modify: `app/pubspec.yaml` (web_socket_channel)
- Modify (add stubs): `app/test/api/docker_api_client_test.dart`, `app/test/api/docker_api_client_logs_test.dart`, `app/test/state/logs_notifier_test.dart`, `app/test/ui/logs_screen_test.dart`
- Test: `app/test/transport/agent_transport_exec_test.dart`

**Interfaces:**
- Consumes: existing `AgentTransport`.
- Produces:
  - `abstract class ExecChannel { Stream<List<int>> get output; void send(List<int> data); Future<void> close(); }`
  - `Transport.post(String path, {Map<String,String>? query, Object? body, Map<String,String>? headers}) → Future<http.Response>`
  - `Transport.execAttach(String execId, {required int cols, required int rows}) → Future<ExecChannel>`
  - `AgentTransport` implements both (POST with bearer + JSON; WS via `IOWebSocketChannel` with a bearer handshake header).

- [ ] **Step 1: Add the dependency**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter pub add web_socket_channel && cd ..`
Expected: resolves; `pubspec.yaml`/`pubspec.lock` updated.

- [ ] **Step 2: Write the failing test**

Create `app/test/transport/agent_transport_exec_test.dart`:
```dart
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';

void main() {
  test('post sends JSON body and bearer header', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response('{"Id":"x"}', 201);
    });
    final t = AgentTransport(
      baseUri: Uri.parse('http://h:8080'),
      token: 'secret',
      client: mock,
    );

    final resp = await t.post('/containers/c/exec', body: {'Cmd': ['sh']});

    expect(resp.statusCode, 201);
    expect(captured.method, 'POST');
    expect(captured.headers['Authorization'], 'Bearer secret');
    expect(jsonDecode(captured.body), {'Cmd': ['sh']});
  });

  test('post forwards query params (resize)', () async {
    late Uri url;
    final mock = MockClient((req) async {
      url = req.url;
      return http.Response('', 200);
    });
    final t = AgentTransport(baseUri: Uri.parse('http://h:8080'), token: 's', client: mock);
    await t.post('/exec/e/resize', query: {'h': '24', 'w': '80'});
    expect(url.path, '/exec/e/resize');
    expect(url.queryParameters, {'h': '24', 'w': '80'});
  });

  test('execAttach connects, echoes, and carries the bearer header', () async {
    // Local WebSocket echo server that records the handshake Authorization.
    String? auth;
    final server = await HttpServer.bind(InternetAddress.loopbackHost, 0);
    server.listen((req) async {
      auth = req.headers.value('authorization');
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((data) => ws.add(data)); // echo
    });
    addTearDown(() => server.close(force: true));

    final t = AgentTransport(
      baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
      token: 'secret',
    );
    final channel = await t.execAttach('e1', cols: 80, rows: 24);
    final received = <int>[];
    final sub = channel.output.listen(received.addAll);

    channel.send(utf8.encode('ping'));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(utf8.decode(received), 'ping');
    expect(auth, 'Bearer secret');
    await sub.cancel();
    await channel.close();
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/agent_transport_exec_test.dart`
Expected: FAIL — `post`/`execAttach` not defined.

- [ ] **Step 4: Extend the Transport interface**

Replace `app/lib/src/transport/transport.dart` with:
```dart
import 'package:http/http.dart' as http;

/// Thrown into a [Transport.stream] when the daemon responds with a non-200.
class TransportException implements Exception {
  final int statusCode;
  final String body;
  const TransportException(this.statusCode, this.body);

  @override
  String toString() => 'TransportException($statusCode): $body';
}

/// A live bidirectional exec session (WebSocket over the agent in 1B).
abstract class ExecChannel {
  Stream<List<int>> get output;
  void send(List<int> data);
  Future<void> close();
}

/// Moves Docker Engine API requests to a daemon. 1B implements only
/// [AgentTransport]; TCP+TLS and SSH transports arrive in sub-project D.
abstract class Transport {
  Future<http.Response> get(String path, {Map<String, String>? query});

  /// Streaming GET (logs/stats/events). Canceling closes the connection.
  Stream<List<int>> stream(String path, {Map<String, String>? query});

  /// POST with an optional JSON body and/or query params.
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers});

  /// Open an interactive exec session by WebSocket bridge.
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows});
}
```

- [ ] **Step 5: Implement in AgentTransport**

In `app/lib/src/transport/agent_transport.dart`: add imports `import 'dart:convert';` and `import 'package:web_socket_channel/io.dart';`, then add these methods to the class (after `stream`):
```dart
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    final h = <String, String>{'Authorization': 'Bearer $token', ...?headers};
    String? encoded;
    if (body != null) {
      encoded = body is String ? body : jsonEncode(body);
      h['Content-Type'] = 'application/json';
    }
    return _client.post(uri, headers: h, body: encoded);
  }

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async {
    final wsScheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    final uri = baseUri.replace(
      scheme: wsScheme,
      path: '/exec/$execId/ws',
      queryParameters: {'w': '$cols', 'h': '$rows'},
    );
    final channel = IOWebSocketChannel.connect(uri, headers: {'Authorization': 'Bearer $token'});
    await channel.ready;
    return _WebSocketExecChannel(channel);
  }
```
And add this class at the bottom of the file:
```dart
class _WebSocketExecChannel implements ExecChannel {
  final IOWebSocketChannel _channel;
  _WebSocketExecChannel(this._channel);

  @override
  Stream<List<int>> get output =>
      _channel.stream.map((e) => e is String ? utf8.encode(e) : e as List<int>);

  @override
  void send(List<int> data) => _channel.sink.add(data);

  @override
  Future<void> close() => _channel.sink.close();
}
```

- [ ] **Step 6: Update existing Transport fakes (compile fix)**

Each test file below defines a class `implements Transport`; add these two stubs to **every** such fake class (they don't use exec): `_FakeTransport` in `app/test/api/docker_api_client_test.dart`, `_FakeTransport` in `app/test/api/docker_api_client_logs_test.dart`, `_FakeTransport` **and** `_ControllerTransport` in `app/test/state/logs_notifier_test.dart`, `_FakeTransport` in `app/test/ui/logs_screen_test.dart`:
```dart
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) =>
      throw UnimplementedError();

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
```
Add `import 'package:docker_mobile/src/transport/transport.dart';` to any of those files that does not already import it (for the `ExecChannel` type).

- [ ] **Step 7: Run the tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; all tests pass (new exec-transport tests + every prior suite).

- [ ] **Step 8: Commit**

```bash
git add app/lib/src/transport app/pubspec.yaml app/pubspec.lock app/test
git commit -m "feat(app): Transport.post + ExecChannel + AgentTransport WebSocket exec"
```

---

## Task 4: App — ExecInspect model

**Files:**
- Create: `app/lib/src/api/models/exec_inspect.dart`
- Test: `app/test/api/models/exec_inspect_test.dart`

**Interfaces:**
- Produces: `class ExecInspect { final bool running; final int? exitCode; const ExecInspect({required this.running, this.exitCode}); factory ExecInspect.fromJson(Map<String,dynamic>); }` reading `Running`, `ExitCode`.

- [ ] **Step 1: Write the failing test**

Create `app/test/api/models/exec_inspect_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/exec_inspect.dart';

void main() {
  test('parses /exec/{id}/json', () {
    final e = ExecInspect.fromJson({'Running': false, 'ExitCode': 137});
    expect(e.running, isFalse);
    expect(e.exitCode, 137);
  });

  test('tolerates a null exit code while running', () {
    final e = ExecInspect.fromJson({'Running': true, 'ExitCode': null});
    expect(e.running, isTrue);
    expect(e.exitCode, isNull);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/exec_inspect_test.dart`
Expected: FAIL — `ExecInspect` undefined.

- [ ] **Step 3: Write the implementation**

Create `app/lib/src/api/models/exec_inspect.dart`:
```dart
/// Subset of `GET /exec/{id}/json`.
class ExecInspect {
  final bool running;
  final int? exitCode;
  const ExecInspect({required this.running, this.exitCode});

  factory ExecInspect.fromJson(Map<String, dynamic> json) => ExecInspect(
        running: json['Running'] as bool? ?? false,
        exitCode: json['ExitCode'] as int?,
      );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/exec_inspect_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/models/exec_inspect.dart app/test/api/models/exec_inspect_test.dart
git commit -m "feat(app): ExecInspect model"
```

---

## Task 5: App — DockerApiClient exec methods

**Files:**
- Modify: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/docker_api_client_exec_test.dart`

**Interfaces:**
- Consumes: `Transport` (Task 3), `ExecInspect` (Task 4), `ExecChannel` (Task 3).
- Produces, on `DockerApiClient`:
  - `Future<String> createExec(String containerId, {required List<String> cmd, bool tty = true})`
  - `Future<ExecChannel> attachExec(String execId, {required int cols, required int rows})`
  - `Future<void> resizeExec(String execId, {required int cols, required int rows})`
  - `Future<ExecInspect> inspectExec(String execId)`

- [ ] **Step 1: Write the failing test**

Create `app/test/api/docker_api_client_exec_test.dart`:
```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _FakeTransport implements Transport {
  http.Response getResponse = http.Response('{}', 200);
  http.Response postResponse = http.Response('{}', 201);
  String? postPath;
  Object? postBody;
  Map<String, String>? postQuery;

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => getResponse;

  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    postPath = path;
    postBody = body;
    postQuery = query;
    return postResponse;
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
}

void main() {
  test('createExec posts the exec config and returns the Id', () async {
    final t = _FakeTransport()..postResponse = http.Response('{"Id":"e123"}', 201);
    final id = await DockerApiClient(t).createExec('c1', cmd: ['/bin/sh']);

    expect(id, 'e123');
    expect(t.postPath, '/containers/c1/exec');
    final body = t.postBody as Map<String, dynamic>;
    expect(body['Tty'], true);
    expect(body['AttachStdin'], true);
    expect(body['Cmd'], ['/bin/sh']);
  });

  test('resizeExec posts h and w as query params', () async {
    final t = _FakeTransport()..postResponse = http.Response('', 200);
    await DockerApiClient(t).resizeExec('e1', cols: 120, rows: 40);
    expect(t.postPath, '/exec/e1/resize');
    expect(t.postQuery, {'h': '40', 'w': '120'});
  });

  test('inspectExec parses running + exit code', () async {
    final t = _FakeTransport()..getResponse = http.Response('{"Running":false,"ExitCode":0}', 200);
    final e = await DockerApiClient(t).inspectExec('e1');
    expect(e.running, isFalse);
    expect(e.exitCode, 0);
  });

  test('createExec throws on non-201', () async {
    final t = _FakeTransport()..postResponse = http.Response('boom', 500);
    expect(() => DockerApiClient(t).createExec('c1', cmd: ['sh']),
        throwsA(isA<DockerApiException>()));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/docker_api_client_exec_test.dart`
Expected: FAIL — exec methods undefined.

- [ ] **Step 3: Add the methods**

In `app/lib/src/api/docker_api_client.dart`, add `import 'models/exec_inspect.dart';` and append these methods inside `DockerApiClient`:
```dart
  Future<String> createExec(String containerId, {required List<String> cmd, bool tty = true}) async {
    final resp = await transport.post('/containers/$containerId/exec', body: {
      'AttachStdin': true,
      'AttachStdout': true,
      'AttachStderr': true,
      'Tty': tty,
      'Cmd': cmd,
    });
    if (resp.statusCode != 201) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    return (jsonDecode(resp.body) as Map<String, dynamic>)['Id'] as String;
  }

  Future<ExecChannel> attachExec(String execId, {required int cols, required int rows}) =>
      transport.execAttach(execId, cols: cols, rows: rows);

  Future<void> resizeExec(String execId, {required int cols, required int rows}) async {
    final resp = await transport.post('/exec/$execId/resize', query: {'h': '$rows', 'w': '$cols'});
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
  }

  Future<ExecInspect> inspectExec(String execId) async {
    final resp = await transport.get('/exec/$execId/json');
    if (resp.statusCode != 200) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    return ExecInspect.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/ && flutter analyze`
Expected: PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/docker_api_client.dart app/test/api/docker_api_client_exec_test.dart
git commit -m "feat(app): DockerApiClient exec methods (create/attach/resize/inspect)"
```

---

## Task 6: App — ExecSessionController, ExecScreen, container entry, xterm

**Files:**
- Modify: `app/pubspec.yaml` (xterm)
- Create: `app/lib/src/state/exec_session_controller.dart`
- Create: `app/lib/src/ui/exec_screen.dart`
- Modify: `app/lib/src/ui/containers_screen.dart`
- Test: `app/test/state/exec_session_controller_test.dart`
- Test: `app/test/ui/exec_screen_test.dart`

**Interfaces:**
- Consumes: `DockerApiClient` exec methods (Task 5), `ExecChannel` (Task 3), `dockerClientProvider`.
- Produces:
  - `enum ExecStatus { connecting, connected, ended, error }`
  - `class ExecSessionController extends ChangeNotifier` with `Terminal terminal`, `ExecStatus status`, `int? exitCode`, `String command`, `void restart(String command)`.
  - `class ExecScreen extends ConsumerStatefulWidget { const ExecScreen({required this.containerId, required this.containerName}); }`
  - `ContainersScreen` row gets a trailing terminal `IconButton` → `ExecScreen`.

- [ ] **Step 1: Add the dependency**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter pub add xterm && cd ..`
Expected: resolves; note the resolved `xterm` version (this plan targets xterm 4.x: `Terminal()`, `terminal.write(String)`, `terminal.onOutput`, `terminal.onResize`, `terminal.viewWidth`/`viewHeight`, `TerminalView(terminal)`). If the resolved version differs, adapt those member names per its API; do not leave it uncompiling.

- [ ] **Step 2: Write the failing controller test**

Create `app/test/state/exec_session_controller_test.dart`:
```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/exec_session_controller.dart';

class _FakeExecChannel implements ExecChannel {
  final controller = StreamController<List<int>>();
  final sent = <List<int>>[];
  @override
  Stream<List<int>> get output => controller.stream;
  @override
  void send(List<int> data) => sent.add(data);
  @override
  Future<void> close() => controller.close();
}

class _ExecFakeTransport implements Transport {
  final _FakeExecChannel channel;
  final String execId;
  final int exitCode;
  _ExecFakeTransport({required this.channel, required this.execId, this.exitCode = 0});

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async =>
      http.Response('{"Running":false,"ExitCode":$exitCode}', 200);
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('{"Id":"$execId"}', 201);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async => channel;
}

void main() {
  test('forwards terminal input to the channel', () async {
    final ch = _FakeExecChannel();
    final client = DockerApiClient(_ExecFakeTransport(channel: ch, execId: 'e1'));
    final c = ExecSessionController(client, 'cid');
    await pumpEventQueue();
    expect(c.status, ExecStatus.connected);

    c.terminal.onOutput?.call('hi');
    expect(ch.sent.map(utf8.decode).toList(), ['hi']);
    c.dispose();
  });

  test('status becomes ended with the exit code when output closes', () async {
    final ch = _FakeExecChannel();
    final client = DockerApiClient(_ExecFakeTransport(channel: ch, execId: 'e1', exitCode: 137));
    final c = ExecSessionController(client, 'cid');
    await pumpEventQueue();

    await ch.controller.close();
    await pumpEventQueue();

    expect(c.status, ExecStatus.ended);
    expect(c.exitCode, 137);
    c.dispose();
  });
}
```

- [ ] **Step 3: Run the controller test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/state/exec_session_controller_test.dart`
Expected: FAIL — `ExecSessionController` undefined.

- [ ] **Step 4: Write the controller**

Create `app/lib/src/state/exec_session_controller.dart`:
```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';

import '../api/docker_api_client.dart';
import '../transport/transport.dart';

enum ExecStatus { connecting, connected, ended, error }

/// Default command: try bash, fall back to sh, in a single exec.
const _defaultShell = [
  '/bin/sh',
  '-c',
  'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi',
];

class ExecSessionController extends ChangeNotifier {
  final DockerApiClient client;
  final String containerId;
  final Terminal terminal = Terminal(maxLines: 10000);

  ExecChannel? _channel;
  StreamSubscription<List<int>>? _outputSub;
  String? _execId;
  ExecStatus status = ExecStatus.connecting;
  int? exitCode;
  String command = ''; // empty => default bash/sh chooser

  ExecSessionController(this.client, this.containerId) {
    terminal.onOutput = (data) => _channel?.send(utf8.encode(data));
    terminal.onResize = (w, h, pw, ph) {
      final id = _execId;
      if (id != null) {
        client.resizeExec(id, cols: w, rows: h);
      }
    };
    _start();
  }

  List<String> get _cmd =>
      command.trim().isEmpty ? _defaultShell : ['/bin/sh', '-c', command];

  Future<void> _start() async {
    status = ExecStatus.connecting;
    exitCode = null;
    notifyListeners();
    try {
      _execId = await client.createExec(containerId, cmd: _cmd, tty: true);
      final ch = await client.attachExec(_execId!, cols: terminal.viewWidth, rows: terminal.viewHeight);
      _channel = ch;
      status = ExecStatus.connected;
      notifyListeners();
      _outputSub = ch.output.listen(
        (bytes) => terminal.write(utf8.decode(bytes, allowMalformed: true)),
        onDone: _onEnded,
        onError: (_) => _onEnded(),
      );
    } catch (_) {
      status = ExecStatus.error;
      notifyListeners();
    }
  }

  Future<void> _onEnded() async {
    status = ExecStatus.ended;
    final id = _execId;
    if (id != null) {
      try {
        exitCode = (await client.inspectExec(id)).exitCode;
      } catch (_) {/* leave exitCode null */}
    }
    notifyListeners();
  }

  Future<void> restart(String newCommand) async {
    command = newCommand;
    await _outputSub?.cancel();
    await _channel?.close();
    await _start();
  }

  @override
  void dispose() {
    _outputSub?.cancel();
    _channel?.close();
    super.dispose();
  }
}
```

- [ ] **Step 5: Run the controller test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/state/exec_session_controller_test.dart`
Expected: PASS (both tests).

- [ ] **Step 6: Write the ExecScreen + failing widget test**

Create `app/test/ui/exec_screen_test.dart`:
```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:xterm/xterm.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/exec_screen.dart';

class _FakeExecChannel implements ExecChannel {
  final controller = StreamController<List<int>>();
  @override
  Stream<List<int>> get output => controller.stream;
  @override
  void send(List<int> data) {}
  @override
  Future<void> close() => controller.close();
}

class _FakeTransport implements Transport {
  final _FakeExecChannel channel;
  _FakeTransport(this.channel);
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async =>
      http.Response('{"Running":false,"ExitCode":0}', 200);
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('{"Id":"e1"}', 201);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async => channel;
}

void main() {
  testWidgets('renders the terminal and command bar, then shows session ended', (tester) async {
    final ch = _FakeExecChannel();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [transportProvider.overrideWith((ref) => _FakeTransport(ch))],
        child: const MaterialApp(home: ExecScreen(containerId: 'a', containerName: 'web')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget); // app bar title
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); // command bar

    await ch.controller.close(); // process exits
    await tester.pumpAndSettle();
    expect(find.textContaining('ended'), findsOneWidget);
  });
}
```

Create `app/lib/src/ui/exec_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';

import '../state/exec_session_controller.dart';
import '../state/providers.dart';

class ExecScreen extends ConsumerStatefulWidget {
  final String containerId;
  final String containerName;
  const ExecScreen({super.key, required this.containerId, required this.containerName});

  @override
  ConsumerState<ExecScreen> createState() => _ExecScreenState();
}

class _ExecScreenState extends ConsumerState<ExecScreen> {
  ExecSessionController? _session;
  final _cmd = TextEditingController();

  @override
  void initState() {
    super.initState();
    final client = ref.read(dockerClientProvider);
    if (client != null) {
      _session = ExecSessionController(client, widget.containerId)..addListener(_onChange);
    }
  }

  void _onChange() => setState(() {});

  @override
  void dispose() {
    _session?.removeListener(_onChange);
    _session?.dispose();
    _cmd.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return Scaffold(
      appBar: AppBar(title: Text(widget.containerName)),
      body: session == null
          ? const Center(child: Text('Not connected'))
          : Column(
              children: [
                _CommandBar(controller: _cmd, onRun: () => session.restart(_cmd.text)),
                if (session.status == ExecStatus.error)
                  MaterialBanner(
                    content: const Text('Exec failed'),
                    actions: [TextButton(onPressed: () => session.restart(_cmd.text), child: const Text('Retry'))],
                  ),
                if (session.status == ExecStatus.ended)
                  MaterialBanner(
                    content: Text('Session ended${session.exitCode != null ? ' (exit ${session.exitCode})' : ''}'),
                    actions: [TextButton(onPressed: () => session.restart(_cmd.text), child: const Text('Restart'))],
                  ),
                Expanded(child: TerminalView(session.terminal)),
              ],
            ),
    );
  }
}

class _CommandBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onRun;
  const _CommandBar({required this.controller, required this.onRun});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: controller,
              decoration: const InputDecoration(
                hintText: 'Command (blank = auto shell)',
                isDense: true,
              ),
            ),
          ),
          IconButton(tooltip: 'Run', icon: const Icon(Icons.play_arrow), onPressed: onRun),
        ],
      ),
    );
  }
}
```

- [ ] **Step 7: Wire the container entry point**

In `app/lib/src/ui/containers_screen.dart`, add `import 'exec_screen.dart';`, then give the `ListTile` a `trailing` exec button (it already has `onTap` → logs):
```dart
              trailing: IconButton(
                tooltip: 'Exec',
                icon: const Icon(Icons.terminal),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ExecScreen(containerId: c.id, containerName: name),
                  ),
                ),
              ),
```

- [ ] **Step 8: Run the widget test + full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; **all** app tests pass.

- [ ] **Step 9: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/src/state/exec_session_controller.dart app/lib/src/ui/exec_screen.dart app/lib/src/ui/containers_screen.dart app/test/state/exec_session_controller_test.dart app/test/ui/exec_screen_test.dart
git commit -m "feat(app): interactive exec terminal screen (xterm) with bash->sh default"
```

---

## Self-Review

**1. Spec coverage:**
- Agent `GET /exec/{id}/ws` hijack + WS bridge, behind auth → Tasks 1–2. ✓
- Hand-rolled hijack (no Docker SDK), gorilla/websocket → Tasks 1–2. ✓
- `Transport.post` + `ExecChannel` + `AgentTransport` WS impl → Task 3. ✓
- `ExecInspect` → Task 4. ✓
- `DockerApiClient` create/attach/resize/inspect → Task 5. ✓
- Default bash→sh single-exec command; custom via `sh -c` → Task 6 (`_defaultShell` / `_cmd`). ✓
- `ExecScreen` xterm wiring (output→write, onOutput→send, onResize→resize), restart, exit display; container trailing exec icon → Task 6. ✓
- Error handling (WS/exec failure → banner+retry; exit → ended+code; leaving closes channel) → Tasks 2/6. ✓
- Resize as separate proxied POST → Task 5 (`resizeExec`). ✓
- Testing (fake-socket bridge echo + auth; post/execAttach; client; controller; widget) → across tasks. ✓
- Out of scope (direct TCP/SSH exec, multi-session, non-TTY) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code step is complete; the xterm note gives the exact 4.x member names to use with an explicit "adapt if the version differs" — concrete, not vague.

**3. Type consistency:** `ExecChannel{output,send,close}` (Task 3) used by Task 5 (`attachExec`) and Task 6 (controller/fakes). `Transport.post(path,{query,body,headers})` (Task 3) called identically in Task 5. `DockerApiClient.createExec(id,{cmd,tty})`/`resizeExec(id,{cols,rows})`/`inspectExec`/`attachExec(id,{cols,rows})` (Task 5) used by the controller (Task 6). `ExecInspect{running,exitCode}` (Task 4) used by Task 5/6. Agent: `startExecHijack(ctx,dial,execID)` (Task 1) used by `NewHandler` (Task 2); `NewHandler(dockerHost)(http.Handler,error)` used by `server.Handler` (Task 2). `r.PathValue("id")` matches the `GET /exec/{id}/ws` pattern. ✓
