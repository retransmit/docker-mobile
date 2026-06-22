# docker-mobile Phase 1B — Interactive Exec Terminal — Design Spec

**Date:** 2026-06-20
**Status:** Approved (brainstorming) — pending user review of written spec
**Builds on:** Phase 0 + Phase 1A (agent + app + streaming foundation on `main`). Sub-project B of Phase 1 (A/B/C/D).

---

## 1. Summary

Phase 1B adds an **interactive shell in a container** from the phone. Docker's exec endpoint has no WebSocket variant and the phone can't reach the Docker socket, so the **agent bridges a WebSocket ⇄ Docker's hijacked exec stream**. The app creates an exec (via the existing proxy), opens a WebSocket to the agent for the live bidirectional session, and renders it in an xterm terminal with TTY resize. The default shell command tries bash and falls back to sh in a single exec.

## 2. Goals / Non-goals

**Goals**
- Agent: a `GET /exec/{id}/ws` endpoint that performs the exec-start hijack (hand-rolled) and bridges it to a WebSocket, behind the existing token auth.
- App: `Transport.post` + an `ExecChannel` abstraction + `AgentTransport` WebSocket implementation; `DockerApiClient` exec methods; an `ExecScreen` xterm terminal with resize, restart, and exit display.
- Default command: `/bin/sh -c 'if command -v bash …; then exec bash; else exec sh; fi'`; user-overridable.

**Non-goals (this slice)**
- Direct TCP+TLS / SSH exec (the raw client-side hijack) — sub-project D (`execAttach` for those transports throws `UnimplementedError` for now).
- Multiple concurrent exec sessions per container; attach-to-running-process (`/attach`); non-TTY exec.
- Resource breadth / lifecycle actions — sub-project C.

## 3. Scope decisions (locked)

- **Hijack:** hand-rolled raw HTTP hijack in the agent (no Docker Go SDK); WebSocket via `gorilla/websocket`.
- **Default shell:** single exec running `/bin/sh -c 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi'`. A command bar overrides it; custom input runs as `sh -c "<input>"`.
- **Transport:** agent-only for B. `Transport.execAttach`/`post` implemented by `AgentTransport`; other transports defer to D.
- **Resize:** sent as a separate `POST /exec/{id}/resize?h=&w=` through the proxy (not multiplexed into the WS).

## 4. Architecture

```
ContainersScreen --terminal icon--> ExecScreen (xterm)
  1. createExec : POST /containers/{id}/exec  {Tty:true, AttachStdin/out/err:true, Cmd:[…]} -> {Id}   (proxied; Transport.post)
  2. attachExec : WebSocket GET /exec/{id}/ws  (bearer header, ?w=&h=)  -> ExecChannel
        agent /exec/{id}/ws handler: upgrade WS  <-->  hijack POST /exec/{id}/start {Tty:true}
        bridge: WS msg -> conn (stdin) ; conn read -> WS msg (stdout, raw TTY stream)
  3. resize     : POST /exec/{id}/resize?h=&w=   (proxied) on terminal size change
  4. exit       : process ends -> conn closes -> agent closes WS -> "session ended"; GET /exec/{id}/json -> exit code
```

## 5. Components

### 5.1 Agent (Go) — new dep `github.com/gorilla/websocket`
- `internal/exec/bridge.go`:
  - `startExecHijack(dial dockerhost.DialFunc, execId string) (net.Conn, error)` — dials the daemon, writes `POST /exec/{execId}/start HTTP/1.1` with `Content-Type: application/json`, `Connection: Upgrade`, `Upgrade: tcp`, body `{"Detach":false,"Tty":true}`; reads response headers until `\r\n\r\n`; on `101`/`200` returns the raw `net.Conn`, else an error.
  - `Handler(dockerHost string) http.Handler` — upgrades the request to a WebSocket (`gorilla/websocket.Upgrader`), extracts `{id}` from the path, calls `startExecHijack`, then runs two goroutines: WS binary message → `conn.Write`; `conn` read loop → WS binary message. Closes both when either side ends or errors.
- `internal/server/server.go` — register `GET /exec/{id}/ws` → `auth.RequireToken(token, exec.Handler(dockerHost))`. (Go 1.22+ `ServeMux` method+wildcard patterns; module go 1.23.)

### 5.2 App (Dart) — new deps `web_socket_channel`, `xterm`
- `Transport` additions:
  - `Future<http.Response> post(String path, {Object? body, Map<String,String>? headers})`
  - `Future<ExecChannel> execAttach(String execId, {required int cols, required int rows})`
  - `class ExecChannel { Stream<List<int>> get output; void send(List<int> data); Future<void> close(); }`
- `AgentTransport`:
  - `post` → HTTP POST with the bearer header (JSON body when `body` is a Map/String).
  - `execAttach` → `IOWebSocketChannel.connect(baseUri /exec/{id}/ws?w=&h=, headers: {Authorization: Bearer …})`; wraps the channel as an `ExecChannel` (output = channel.stream cast to bytes; send → channel.sink.add; close → channel.sink.close).
- `DockerApiClient`:
  - `Future<String> createExec(String containerId, {required List<String> cmd, bool tty = true})` — POST `/containers/{id}/exec`, parse `{Id}`.
  - `Future<ExecChannel> attachExec(String execId, {required int cols, required int rows})` — delegates to `transport.execAttach`.
  - `Future<void> resizeExec(String execId, {required int cols, required int rows})` — POST `/exec/{id}/resize?h=rows&w=cols`.
  - `Future<ExecInspect> inspectExec(String execId)` — GET `/exec/{id}/json` → `ExecInspect{bool running, int? exitCode}`.
- `ExecScreen` (xterm): owns a `Terminal`; on open, `createExec` (default or custom cmd) → `attachExec` → wires `terminal.onOutput` → `channel.send`, `channel.output` → `terminal.write`, `terminal.onResize` → `resizeExec`. A command bar restarts the session with a new command. On channel close, shows "session ended (exit N)" via `inspectExec`.
- `ContainersScreen` — each row gets a trailing terminal `IconButton` → `ExecScreen(containerId, name)`; tapping the row still opens `LogsScreen`.

### 5.3 Models
- `ExecInspect { final bool running; final int? exitCode; factory ExecInspect.fromJson(...) }` reading `Running`, `ExitCode`.

## 6. Error handling
- WS connect failure / 401 → `ExecScreen` shows an error banner + Retry.
- Exec start failure or process exit → stream closes → "session ended", exit code from `inspectExec`.
- Leaving `ExecScreen` closes the `ExecChannel` (WS) → agent closes the hijacked conn (no leaked stream). The agent bridge closes both sides if either errors.
- Agent: `startExecHijack` returns an error on non-101/200; the handler closes the WS with a reason.

## 7. File structure
```
agent/go.mod                                  # + gorilla/websocket
agent/internal/exec/bridge.go                 # startExecHijack + Handler
agent/internal/exec/bridge_test.go
agent/internal/server/server.go               # route GET /exec/{id}/ws

app/lib/src/transport/transport.dart          # + post, execAttach, ExecChannel
app/lib/src/transport/agent_transport.dart    # + post, execAttach (IOWebSocketChannel)
app/lib/src/api/models/exec_inspect.dart      # ExecInspect
app/lib/src/api/docker_api_client.dart        # + createExec/attachExec/resizeExec/inspectExec
app/lib/src/ui/exec_screen.dart               # ExecScreen
app/lib/src/ui/containers_screen.dart         # trailing exec icon
app/pubspec.yaml                              # + web_socket_channel, xterm
app/test/...                                   # mirrors the above
```

## 8. Testing
- **Agent** (`bridge_test.go`): a fake Docker socket TCP server that reads the `POST /exec/{id}/start`, replies `101 UPGRADED\r\n\r\n`, then echoes. Test: connect a real `gorilla/websocket` client to the agent's `/exec/{id}/ws`, send bytes → assert they arrive at the fake socket; have the fake socket send bytes → assert they arrive over the WS. Also assert auth is required (no token → rejected).
- **App**:
  - `AgentTransport.post` — `MockClient` asserts method/body/bearer.
  - `AgentTransport.execAttach` — against a local `dart:io` `HttpServer` upgraded to WebSocket (echo); assert send/receive and that close closes the socket.
  - `DockerApiClient` — fake transport: `createExec` posts the right body and parses `{Id}`; `resizeExec` builds `?h=&w=`; `inspectExec` parses running/exitCode.
  - `ExecScreen` widget test — inject a fake `ExecChannel` (StreamController-backed); assert terminal input is forwarded to `send` and channel output is written to the terminal; assert "session ended" shows on close.

## 9. Dependencies
- Agent: `github.com/gorilla/websocket`.
- App: `web_socket_channel`, `xterm`.

## 10. Open questions / to confirm during planning
- Exact xterm.dart API surface for input/output/resize hooks (pin the version and adapt the wiring).
- WebSocket message framing: send terminal bytes as **binary** messages (recommended) vs text; the agent treats both as raw bytes.
- Whether to kill the exec process on disconnect (Docker leaves it running); acceptable to leave for this slice.
