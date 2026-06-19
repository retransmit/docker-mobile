# docker-mobile Phase 1A — Streaming Foundation & Live Logs — Design Spec

**Date:** 2026-06-20
**Status:** Approved (brainstorming) — pending user review of written spec
**Builds on:** Phase 0 (agent + app on `main`). Part of Phase 1 (sub-project A of A/B/C/D).

---

## 1. Summary

Phase 1A adds the app's **streaming foundation** and the first feature built on it: a **rich live container-log viewer**. It extends the `Transport` interface with a streamed-bytes method, adds a robust **stdcopy demultiplexer**, a small **real-time flush** tweak to the agent's proxy, and a full-featured **logs screen** (live follow, tail-N, search/filter + highlight, stdout/stderr coloring, timestamps toggle, adjustable tail, autoscroll + jump-to-latest, download/share). The streaming layer is built generically so Phase-1 stats/events can reuse it.

## 2. Goals / Non-goals

**Goals**
- Add `Transport.stream(...) → Stream<List<int>>` and implement it for `AgentTransport` over streamed HTTP, with clean cancellation.
- A correct, well-tested `StdcopyDecoder` (Docker's 8-byte multiplexed frames) + a TTY raw passthrough.
- A **rich** live-log viewer: follow, tail-N (adjustable), search/filter with highlight, stdout/stderr color, timestamps toggle, autoscroll + jump-to-latest, download/share.
- Make the agent stream in real time (`ReverseProxy.FlushInterval = -1`).

**Non-goals (this slice)**
- WebSocket bridging (introduced in sub-project B for exec, where it is required).
- Stats/events viewers (later; they reuse the same streaming foundation).
- TCP+TLS / SSH `Transport.stream` implementations (sub-project D).
- Multi-container / aggregated log views.

## 3. Scope decisions (locked)

- **Streaming mechanism:** streamed HTTP over the existing transparent proxy (NOT WebSocket). Rationale: log/stat/event streams are one-directional; the proxy already forwards chunked responses; only a flush flag is needed. WebSocket is reserved for bidirectional hijacked exec (sub-project B).
- **Log viewer richness:** "Rich" — Core+search PLUS timestamps toggle, adjustable tail size, and download/share.

## 4. Architecture

```
ContainersScreen --tap--> LogsScreen
                              │ watches
                              ▼
                        LogsNotifier (Riverpod, .family by container id)
                              │ subscribes
                              ▼
   DockerApiClient.streamContainerLogs(id, tty, follow, tail, timestamps, stdout, stderr)
        │  inspectContainer(id) -> tty                    │ returns Stream<LogChunk>
        ▼                                                 ▼
   Transport.stream('/containers/{id}/logs', query) ──► StdcopyDecoder (non-TTY)
        │  (AgentTransport: http.Client.send, cancelable)   RawLogDecoder (TTY)
        ▼
   docker-mobile-agent  (ReverseProxy, FlushInterval = -1)  ──►  dockerd /containers/{id}/logs
```

Streamed HTTP end-to-end; the agent flushes each chunk immediately; the app demuxes and renders.

## 5. Components

### 5.1 Transport (app)
- **`Transport.stream(String path, {Map<String,String>? query}) → Stream<List<int>>`** added to the interface.
- **`AgentTransport.stream`** — opens a dedicated `http.Client`, builds an `http.Request` (GET, bearer header), `send()`s it, and exposes `StreamedResponse.stream`. Wrapped in a `StreamController` whose `onCancel` aborts the request and closes the client, so leaving the screen stops Docker following. Non-200 responses surface as a stream error carrying the status + body.

### 5.2 stdcopy demux (app) — `lib/src/api/stdcopy.dart`
- **`LogChunk { LogStream source; List<int> bytes; }`** where `LogStream` ∈ {stdout, stderr}.
- **`StdcopyDecoder`** — `StreamTransformer<List<int>, LogChunk>`. Maintains a byte accumulator; parses repeating `[8-byte header][payload]` frames: byte0 = stream type (1=stdout, 2=stderr; 0 treated as stdout), bytes4-7 = uint32 big-endian payload length. Handles headers and payloads **split across input chunks**. Emits a `LogChunk` per (re)assembled payload slice. Malformed input never throws — on an unparseable header it emits the remaining bytes as a stderr chunk and resets (defensive).
- **`RawLogDecoder`** — pass-through transformer for **TTY** streams: every input chunk → one stdout `LogChunk`.

### 5.3 Models (app)
- **`ContainerInspect { String id; String name; String image; String state; bool tty; }`** with `fromJson` reading `Id`, `Name`, `Config.Image`, `State.Status`, `Config.Tty` from `GET /containers/{id}/json`. Minimal now; expandable in sub-project C.
- **`LogLine { LogStream source; String text; DateTime? timestamp; }`** — one rendered line (timestamp parsed from the leading RFC3339 token when timestamps are enabled).

### 5.4 DockerApiClient (app) — additions
- `Future<ContainerInspect> inspectContainer(String id)` — GET `/containers/{id}/json`, throws `DockerApiException` on non-200.
- `Stream<LogChunk> streamContainerLogs(String id, {required bool tty, bool follow = true, int? tail, bool timestamps = false, bool stdout = true, bool stderr = true})` — builds the query (`follow`, `stdout`, `stderr`, `tail` (default `all`/number), `timestamps`), calls `transport.stream`, and pipes through `StdcopyDecoder` (non-TTY) or `RawLogDecoder` (TTY).

### 5.5 State (app) — `LogsNotifier`
- A Riverpod `Notifier`/`StateNotifier` keyed by container id holding: a **bounded ring buffer** of `LogLine` (cap, e.g. 5000 lines, oldest dropped); options (`follow`, `timestamps`, `tail`, search query); and a status (streaming / paused / error).
- Assembles incoming `LogChunk`s into `LogLine`s (split on `\n`, carry partial line across chunks per source).
- `follow` toggle starts/stops the subscription; changing `tail`/`timestamps` re-subscribes (clears buffer, re-streams); search updates the filtered view (does not re-stream); `snapshot()` returns the current buffer as text for download.

### 5.6 UI (app) — `lib/src/ui/logs_screen.dart`
- AppBar: container name + actions (follow toggle, timestamps toggle, tail-size menu, download/share).
- A search `TextField` (filter + highlight matches).
- A virtualized `ListView.builder` of lines: stdout = default color, stderr = error color; matched search substrings highlighted; optional leading timestamp.
- Autoscroll to newest while following; a **jump-to-latest** FAB appears when scrolled up.
- Download/share via `share_plus`.
- `ContainersScreen` ListTile gains `onTap` → push `LogsScreen(containerId, name)`.

### 5.7 Agent (Go)
- `internal/proxy/proxy.go`: set `ReverseProxy.FlushInterval = -1` so each chunk flushes to the client immediately (live logs). No other agent change.

## 6. Error handling
- Stream errors (drop / 404 / 401) → `LogsNotifier` enters an error state surfaced as an in-viewer banner with **Retry**, preserving buffered lines.
- `StdcopyDecoder` is defensive: malformed frames never throw (emit-as-stderr + reset).
- Ring buffer bounds memory on very large/over-fast logs.
- `LogsScreen` dispose cancels the subscription → `AgentTransport.stream.onCancel` closes the HTTP connection (no leaked Docker follow).

## 7. File structure
```
app/lib/src/
  transport/transport.dart            # + stream(...)
  transport/agent_transport.dart      # + stream(...) impl (cancelable)
  api/stdcopy.dart                    # LogChunk, LogStream, StdcopyDecoder, RawLogDecoder
  api/models/container_inspect.dart   # ContainerInspect
  api/models/log_line.dart            # LogLine
  api/docker_api_client.dart          # + inspectContainer, streamContainerLogs
  state/logs_notifier.dart            # LogsNotifier + provider(s)
  ui/logs_screen.dart                 # LogsScreen
  ui/containers_screen.dart           # + onTap -> LogsScreen
app/test/...                          # mirrors the above
agent/internal/proxy/proxy.go         # FlushInterval = -1
app/pubspec.yaml                      # + share_plus
```

## 8. Testing
- **`StdcopyDecoder`** (exhaustive, pure-Dart TDD): single frame; multiple frames in one chunk; header split across two chunks; payload split across chunks; stdout/stderr interleaving; empty payload; trailing partial; malformed header → defensive recovery; `RawLogDecoder` passthrough.
- **`AgentTransport.stream`**: `MockClient.streaming` emits chunked bytes → assert byte stream content, bearer header, URL/query; non-200 → stream error; cancel closes.
- **`DockerApiClient`**: fake transport → `inspectContainer` parses `tty`/name; `streamContainerLogs` yields correct `LogChunk`s for TTY vs non-TTY.
- **`LogsNotifier`**: fake stream → line assembly across chunk boundaries, search filter, follow-toggle cancels, ring-buffer cap, error state on stream error.
- **`LogsScreen`** widget test: override providers → renders lines, stdout/stderr colors, search highlight, jump-to-latest visibility.
- **Agent (Go)**: a chunked streamed response is forwarded correctly through the flushing proxy (assert body integrity; document the flush behavior).

## 9. Dependencies
- App: add `share_plus` (download/share logs). No new agent dependencies.

## 10. Open questions / to confirm during planning
- Ring-buffer cap value (default 5000 lines) and whether it's user-adjustable (default: fixed for this slice).
- Exact timestamp parsing/display format (Docker emits RFC3339Nano; display localized short time).
- Whether download writes a temp file then shares, or shares text directly (platform-dependent via `share_plus`).
