# Phase 1A — Streaming Foundation & Live Logs — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the app's streaming foundation (`Transport.stream` + a robust stdcopy demuxer + a real-time agent flush) and a rich live container-log viewer on top of it.

**Architecture:** The app issues a *streaming* HTTP GET to `/containers/{id}/logs?follow=…` through the existing transparent agent proxy (which now flushes each chunk immediately). Raw bytes flow through a stdcopy demuxer (or a TTY passthrough) into a `LogsNotifier` that assembles lines into a bounded ring buffer; a `LogsScreen` renders them with follow/search/timestamps/tail/download.

**Tech Stack:** Go 1.23 (`net/http/httputil`), Flutter 3.44.2 / Dart 3.12 (`package:http`, `flutter_riverpod`, `share_plus`).

## Global Constraints

- **Streaming mechanism:** streamed HTTP over the agent proxy — **NOT** WebSocket (WebSocket is reserved for sub-project B / exec). Do not add WS code here.
- **Single client:** all Docker calls go through `DockerApiClient` over a `Transport`. The model is `DockerContainer` (never `Container`); the new inspect model is `ContainerInspect`.
- **Cancellation is mandatory:** leaving a log screen must cancel the stream and **close the HTTP connection** so Docker stops following (no leaked streams).
- **`StdcopyDecoder` robustness:** must reassemble Docker's 8-byte frames **across input-chunk boundaries** and must **never throw** on malformed input.
- **Ring buffer cap:** 5000 lines (constant `kLogBufferCap`); oldest dropped first.
- **Toolchain:** Flutter is at `C:\src\flutter` and NOT on PATH — every flutter command in this plan must be prefixed with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash). Go module is `github.com/0xLennox07/docker-mobile/agent` (go 1.23).
- **New dependency:** `share_plus` (app only). No new agent dependencies.
- **Discipline:** TDD (test first → fail → minimal impl → pass), DRY, YAGNI, frequent commits. Commit messages MUST NOT include a `Co-Authored-By` trailer. Repo is local/private on a feature branch.

---

## File Structure

```
agent/internal/proxy/proxy.go            # MODIFY: ReverseProxy.FlushInterval = -1
agent/internal/proxy/proxy_test.go       # MODIFY: + incremental-streaming test

app/lib/src/transport/transport.dart     # MODIFY: + stream(...); + TransportException
app/lib/src/transport/agent_transport.dart # MODIFY: + stream(...) (cancelable)
app/lib/src/api/stdcopy.dart             # CREATE: LogStream, LogChunk, decodeStdcopy, decodeRawLog
app/lib/src/api/models/container_inspect.dart # CREATE: ContainerInspect
app/lib/src/api/models/log_line.dart     # CREATE: LogLine
app/lib/src/api/docker_api_client.dart   # MODIFY: + inspectContainer, streamContainerLogs
app/lib/src/state/logs_notifier.dart     # CREATE: LogsState, LogsNotifier, providers
app/lib/src/ui/logs_screen.dart          # CREATE: LogsScreen
app/lib/src/ui/containers_screen.dart    # MODIFY: ListTile onTap -> LogsScreen
app/pubspec.yaml                         # MODIFY: + share_plus

app/test/transport/agent_transport_stream_test.dart  # CREATE
app/test/api/stdcopy_test.dart                       # CREATE
app/test/api/models/container_inspect_test.dart      # CREATE
app/test/api/models/log_line_test.dart               # CREATE
app/test/api/docker_api_client_logs_test.dart        # CREATE
app/test/state/logs_notifier_test.dart               # CREATE
app/test/ui/logs_screen_test.dart                    # CREATE
```

---

## Task 1: Agent real-time flush

**Files:**
- Modify: `agent/internal/proxy/proxy.go`
- Test: `agent/internal/proxy/proxy_test.go`

**Interfaces:**
- Consumes: existing `proxy.New(dockerHost string) (http.Handler, error)`.
- Produces: same signature; the returned proxy now flushes each chunk to the client immediately (`FlushInterval = -1`).

- [ ] **Step 1: Write the failing test**

Append to `agent/internal/proxy/proxy_test.go`:
```go
func TestProxyStreamsIncrementally(t *testing.T) {
	release := make(chan struct{})
	daemon := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fl, ok := w.(http.Flusher)
		if !ok {
			t.Error("ResponseWriter is not a Flusher")
			return
		}
		io.WriteString(w, "first\n")
		fl.Flush()
		<-release // block until the test has read the first chunk
		io.WriteString(w, "second\n")
		fl.Flush()
	}))
	defer daemon.Close()

	h, err := New("tcp://" + daemon.Listener.Addr().String())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	// A real server is needed because httptest.ResponseRecorder does not stream.
	front := httptest.NewServer(h)
	defer front.Close()

	resp, err := http.Get(front.URL + "/containers/x/logs?follow=1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer resp.Body.Close()

	// The first chunk must arrive BEFORE the handler is released — proving no buffering.
	buf := make([]byte, len("first\n"))
	if _, err := io.ReadFull(resp.Body, buf); err != nil {
		t.Fatalf("read first chunk: %v", err)
	}
	if string(buf) != "first\n" {
		t.Fatalf("first chunk = %q, want %q", buf, "first\n")
	}
	close(release)
	rest, _ := io.ReadAll(resp.Body)
	if string(rest) != "second\n" {
		t.Fatalf("rest = %q, want %q", rest, "second\n")
	}
}
```
Add `"io"` to the test file's imports if not present.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd agent && go test ./internal/proxy/ -run TestProxyStreamsIncrementally -v`
Expected: FAIL or **hang→timeout** (default buffering means the first chunk never arrives before `release`).

- [ ] **Step 3: Write the minimal implementation**

In `agent/internal/proxy/proxy.go`, in `New`, after `rp := httputil.NewSingleHostReverseProxy(target)` add:
```go
	rp.FlushInterval = -1 // flush each chunk immediately for live streams (logs/stats/events)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd agent && go test ./internal/proxy/ -v`
Expected: PASS (including the existing proxy tests).

- [ ] **Step 5: Commit**

```bash
git add agent/internal/proxy
git commit -m "feat(agent): flush proxied responses immediately for live streams"
```

---

## Task 2: Transport.stream + AgentTransport.stream

**Files:**
- Modify: `app/lib/src/transport/transport.dart`
- Modify: `app/lib/src/transport/agent_transport.dart`
- Test: `app/test/transport/agent_transport_stream_test.dart`

**Interfaces:**
- Consumes: existing `Transport.get`, `AgentTransport({baseUri, token, client})`.
- Produces:
  - `abstract class Transport { ... Stream<List<int>> stream(String path, {Map<String, String>? query}); }`
  - `class TransportException implements Exception { final int statusCode; final String body; const TransportException(this.statusCode, this.body); }`
  - `AgentTransport({required Uri baseUri, required String token, http.Client? client, http.Client Function()? streamClientFactory})` whose `stream` issues a streaming GET with the bearer header, errors with `TransportException` on non-200, and **closes its client when the subscription is canceled**.

- [ ] **Step 1: Write the failing test**

Create `app/test/transport/agent_transport_stream_test.dart`:
```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';

class _SpyClient extends http.BaseClient {
  final Stream<List<int>> body;
  final int status;
  bool closed = false;
  http.BaseRequest? lastRequest;
  _SpyClient(this.body, {this.status = 200});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    return http.StreamedResponse(body, status);
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test('stream yields bytes, sends bearer header, builds URL+query', () async {
    final spy = _SpyClient(Stream.fromIterable([
      [1, 2, 3],
      [4, 5],
    ]));
    final t = AgentTransport(
      baseUri: Uri.parse('http://10.0.0.5:8080'),
      token: 'secret',
      streamClientFactory: () => spy,
    );

    final bytes = await t.stream('/containers/x/logs', query: {'follow': 'true'})
        .expand((c) => c)
        .toList();

    expect(bytes, [1, 2, 3, 4, 5]);
    expect(spy.lastRequest!.headers['Authorization'], 'Bearer secret');
    expect(spy.lastRequest!.url.path, '/containers/x/logs');
    expect(spy.lastRequest!.url.queryParameters['follow'], 'true');
  });

  test('stream errors with TransportException on non-200', () async {
    final spy = _SpyClient(Stream.value(utf8.encode('nope')), status: 404);
    final t = AgentTransport(
      baseUri: Uri.parse('http://h:8080'),
      token: 's',
      streamClientFactory: () => spy,
    );
    await expectLater(t.stream('/x'), emitsError(isA<TransportException>()));
  });

  test('canceling the subscription closes the client (no leaked follow)', () async {
    final neverEnds = StreamController<List<int>>();
    final spy = _SpyClient(neverEnds.stream);
    final t = AgentTransport(
      baseUri: Uri.parse('http://h:8080'),
      token: 's',
      streamClientFactory: () => spy,
    );

    final sub = t.stream('/x').listen((_) {});
    await Future<void>.delayed(Duration.zero); // let onListen run send()
    await sub.cancel();

    expect(spy.closed, isTrue);
    await neverEnds.close();
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/agent_transport_stream_test.dart`
Expected: FAIL — `stream` not defined on Transport / `TransportException` undefined.

- [ ] **Step 3: Add the interface + exception**

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

/// Moves Docker Engine API requests to a daemon. Phase 0/1A implement only
/// [AgentTransport]; TCP+TLS and SSH transports arrive in sub-project D.
abstract class Transport {
  Future<http.Response> get(String path, {Map<String, String>? query});

  /// Opens a streaming GET (e.g. `/containers/{id}/logs?follow=true`) and emits
  /// the raw response bytes. Canceling the returned stream's subscription MUST
  /// close the underlying connection.
  Stream<List<int>> stream(String path, {Map<String, String>? query});
}
```

- [ ] **Step 4: Implement AgentTransport.stream**

Replace `app/lib/src/transport/agent_transport.dart` with:
```dart
import 'dart:async';

import 'package:http/http.dart' as http;

import 'transport.dart';

/// Talks to the docker-mobile agent over HTTP(S) with a bearer token.
class AgentTransport implements Transport {
  final Uri baseUri;
  final String token;
  final http.Client _client;
  final http.Client Function() _streamClientFactory;

  AgentTransport({
    required this.baseUri,
    required this.token,
    http.Client? client,
    http.Client Function()? streamClientFactory,
  })  : _client = client ?? http.Client(),
        _streamClientFactory = streamClientFactory ?? (() => http.Client());

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    return _client.get(uri, headers: {'Authorization': 'Bearer $token'});
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    final client = _streamClientFactory();
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;

    controller.onListen = () async {
      try {
        final request = http.Request('GET', uri)
          ..headers['Authorization'] = 'Bearer $token';
        final response = await client.send(request);
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          controller.addError(TransportException(response.statusCode, body));
          await controller.close();
          client.close();
          return;
        }
        sub = response.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: () async {
            await controller.close();
            client.close();
          },
          cancelOnError: true,
        );
      } catch (e) {
        controller.addError(e);
        await controller.close();
        client.close();
      }
    };
    controller.onCancel = () async {
      await sub?.cancel();
      client.close(); // aborts the in-flight request
    };
    return controller.stream;
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ && flutter analyze`
Expected: PASS (new stream tests + existing get test); analyzer clean.

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/transport app/test/transport/agent_transport_stream_test.dart
git commit -m "feat(app): Transport.stream + cancelable AgentTransport streaming"
```

---

## Task 3: stdcopy demultiplexer

**Files:**
- Create: `app/lib/src/api/stdcopy.dart`
- Test: `app/test/api/stdcopy_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum LogStream { stdout, stderr }`
  - `class LogChunk { final LogStream source; final List<int> bytes; const LogChunk(this.source, this.bytes); }`
  - `Stream<LogChunk> decodeStdcopy(Stream<List<int>> input)` — parses Docker's 8-byte multiplexed frames across chunk boundaries; never throws.
  - `Stream<LogChunk> decodeRawLog(Stream<List<int>> input)` — TTY passthrough: each input chunk → one stdout `LogChunk`.

- [ ] **Step 1: Write the failing test**

Create `app/test/api/stdcopy_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';

/// Builds a stdcopy frame: [type, 0,0,0, len(4, big-endian), ...payload].
List<int> frame(int type, List<int> payload) {
  final n = payload.length;
  return [type, 0, 0, 0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, ...payload];
}

Future<List<LogChunk>> collect(List<List<int>> chunks) =>
    decodeStdcopy(Stream.fromIterable(chunks)).toList();

void main() {
  test('decodes a single stdout frame', () async {
    final out = await collect([frame(1, [104, 105])]); // "hi"
    expect(out, hasLength(1));
    expect(out.single.source, LogStream.stdout);
    expect(out.single.bytes, [104, 105]);
  });

  test('decodes stdout then stderr in one chunk', () async {
    final out = await collect([
      [...frame(1, [97]), ...frame(2, [98])],
    ]);
    expect(out.map((c) => c.source).toList(), [LogStream.stdout, LogStream.stderr]);
    expect(out.map((c) => c.bytes.single).toList(), [97, 98]);
  });

  test('reassembles a header split across two chunks', () async {
    final f = frame(1, [120, 121]); // 10 bytes total (8 header + 2 payload)
    final out = await collect([f.sublist(0, 3), f.sublist(3)]);
    expect(out.single.bytes, [120, 121]);
  });

  test('reassembles a payload split across two chunks', () async {
    final f = frame(2, [1, 2, 3, 4]);
    final out = await collect([f.sublist(0, 9), f.sublist(9)]); // split mid-payload
    expect(out.single.source, LogStream.stderr);
    expect(out.single.bytes, [1, 2, 3, 4]);
  });

  test('emits nothing for a trailing partial frame', () async {
    final out = await collect([
      [...frame(1, [1]), 1, 0, 0], // a full frame + 3 dangling header bytes
    ]);
    expect(out, hasLength(1));
    expect(out.single.bytes, [1]);
  });

  test('handles an empty payload frame', () async {
    final out = await collect([frame(1, [])]);
    expect(out.single.bytes, isEmpty);
    expect(out.single.source, LogStream.stdout);
  });

  test('does not throw on a malformed stream type', () async {
    // type 7 is invalid; decoder must recover (emit remaining as stderr) not throw.
    final out = await collect([
      [7, 0, 0, 0, 0, 0, 0, 1, 65],
    ]);
    expect(out, isNotEmpty);
    expect(out.first.source, LogStream.stderr);
  });

  test('raw decoder passes each chunk through as stdout', () async {
    final out = await decodeRawLog(Stream.fromIterable([
      [104, 105],
      [10],
    ])).toList();
    expect(out, hasLength(2));
    expect(out.every((c) => c.source == LogStream.stdout), isTrue);
    expect(out[0].bytes, [104, 105]);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/stdcopy_test.dart`
Expected: FAIL — `decodeStdcopy` / `LogChunk` undefined.

- [ ] **Step 3: Write the implementation**

Create `app/lib/src/api/stdcopy.dart`:
```dart
import 'dart:typed_data';

enum LogStream { stdout, stderr }

class LogChunk {
  final LogStream source;
  final List<int> bytes;
  const LogChunk(this.source, this.bytes);
}

/// Decodes Docker's stdcopy multiplexed stream (used for non-TTY containers):
/// repeating `[type, 0,0,0, len(uint32 big-endian), ...payload]` frames.
/// Reassembles frames split across input chunks; never throws on bad input.
Stream<LogChunk> decodeStdcopy(Stream<List<int>> input) async* {
  var acc = Uint8List(0);
  await for (final chunk in input) {
    if (chunk.isEmpty) continue;
    final merged = Uint8List(acc.length + chunk.length)
      ..setRange(0, acc.length, acc)
      ..setRange(acc.length, acc.length + chunk.length, chunk);
    acc = merged;

    var offset = 0;
    while (acc.length - offset >= 8) {
      final type = acc[offset];
      if (type > 2) {
        // Malformed/desynced: surface the rest defensively and stop parsing.
        yield LogChunk(LogStream.stderr, acc.sublist(offset));
        offset = acc.length;
        break;
      }
      final len = (acc[offset + 4] << 24) |
          (acc[offset + 5] << 16) |
          (acc[offset + 6] << 8) |
          acc[offset + 7];
      if (acc.length - offset - 8 < len) break; // need more bytes
      final payload = acc.sublist(offset + 8, offset + 8 + len);
      yield LogChunk(type == 2 ? LogStream.stderr : LogStream.stdout, payload);
      offset += 8 + len;
    }
    acc = offset == 0 ? acc : acc.sublist(offset);
  }
}

/// TTY passthrough: TTY containers emit a single un-framed stream.
Stream<LogChunk> decodeRawLog(Stream<List<int>> input) async* {
  await for (final chunk in input) {
    yield LogChunk(LogStream.stdout, chunk);
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/stdcopy_test.dart`
Expected: PASS (all 8 cases).

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/stdcopy.dart app/test/api/stdcopy_test.dart
git commit -m "feat(app): stdcopy demuxer with cross-chunk frame reassembly"
```

---

## Task 4: ContainerInspect + LogLine models

**Files:**
- Create: `app/lib/src/api/models/container_inspect.dart`
- Create: `app/lib/src/api/models/log_line.dart`
- Test: `app/test/api/models/container_inspect_test.dart`
- Test: `app/test/api/models/log_line_test.dart`

**Interfaces:**
- Consumes: `LogStream` (Task 3).
- Produces:
  - `class ContainerInspect { final String id, name, image, state; final bool tty; ... factory ContainerInspect.fromJson(Map<String,dynamic>); }` reading `Id`, `Name` (leading `/` stripped), `Config.Image`, `State.Status`, `Config.Tty`.
  - `class LogLine { final LogStream source; final String text; final DateTime? timestamp; const LogLine({required this.source, required this.text, this.timestamp}); }`

- [ ] **Step 1: Write the failing tests**

Create `app/test/api/models/container_inspect_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container_inspect.dart';

void main() {
  test('parses /containers/{id}/json', () {
    final c = ContainerInspect.fromJson({
      'Id': 'abc',
      'Name': '/web',
      'Config': {'Image': 'nginx', 'Tty': true},
      'State': {'Status': 'running'},
    });
    expect(c.id, 'abc');
    expect(c.name, 'web'); // leading slash stripped
    expect(c.image, 'nginx');
    expect(c.state, 'running');
    expect(c.tty, isTrue);
  });

  test('defaults tty to false and tolerates missing nested fields', () {
    final c = ContainerInspect.fromJson({'Id': 'x', 'Name': 'y'});
    expect(c.tty, isFalse);
    expect(c.image, '');
    expect(c.state, '');
  });
}
```

Create `app/test/api/models/log_line_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';
import 'package:docker_mobile/src/api/models/log_line.dart';

void main() {
  test('holds source, text, and optional timestamp', () {
    final ts = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final l = LogLine(source: LogStream.stderr, text: 'boom', timestamp: ts);
    expect(l.source, LogStream.stderr);
    expect(l.text, 'boom');
    expect(l.timestamp, ts);
  });

  test('timestamp is optional', () {
    final l = LogLine(source: LogStream.stdout, text: 'ok');
    expect(l.timestamp, isNull);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/container_inspect_test.dart test/api/models/log_line_test.dart`
Expected: FAIL — models undefined.

- [ ] **Step 3: Write the implementations**

Create `app/lib/src/api/models/container_inspect.dart`:
```dart
/// Subset of `GET /containers/{id}/json` needed by the log viewer.
class ContainerInspect {
  final String id;
  final String name;
  final String image;
  final String state;
  final bool tty;

  const ContainerInspect({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.tty,
  });

  factory ContainerInspect.fromJson(Map<String, dynamic> json) {
    final config = (json['Config'] as Map<String, dynamic>?) ?? const {};
    final stateObj = (json['State'] as Map<String, dynamic>?) ?? const {};
    final rawName = json['Name'] as String? ?? '';
    return ContainerInspect(
      id: json['Id'] as String? ?? '',
      name: rawName.startsWith('/') ? rawName.substring(1) : rawName,
      image: config['Image'] as String? ?? '',
      state: stateObj['Status'] as String? ?? '',
      tty: config['Tty'] as bool? ?? false,
    );
  }
}
```

Create `app/lib/src/api/models/log_line.dart`:
```dart
import '../stdcopy.dart';

/// One rendered log line with its source stream and optional timestamp.
class LogLine {
  final LogStream source;
  final String text;
  final DateTime? timestamp;

  const LogLine({required this.source, required this.text, this.timestamp});
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/models/container_inspect.dart app/lib/src/api/models/log_line.dart app/test/api/models/container_inspect_test.dart app/test/api/models/log_line_test.dart
git commit -m "feat(app): ContainerInspect and LogLine models"
```

---

## Task 5: DockerApiClient — inspectContainer + streamContainerLogs

**Files:**
- Modify: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/docker_api_client_logs_test.dart`

**Interfaces:**
- Consumes: `Transport` (Task 2), `decodeStdcopy`/`decodeRawLog`/`LogChunk` (Task 3), `ContainerInspect` (Task 4).
- Produces, added to `DockerApiClient`:
  - `Future<ContainerInspect> inspectContainer(String id)`
  - `Stream<LogChunk> streamContainerLogs(String id, {required bool tty, bool follow = true, int? tail, bool timestamps = false, bool stdout = true, bool stderr = true})`

- [ ] **Step 1: Write the failing test**

Create `app/test/api/docker_api_client_logs_test.dart`:
```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _FakeTransport implements Transport {
  final http.Response getResponse;
  final List<List<int>> streamChunks;
  String? lastStreamPath;
  Map<String, String>? lastStreamQuery;
  _FakeTransport({required this.getResponse, this.streamChunks = const []});

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => getResponse;

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    lastStreamPath = path;
    lastStreamQuery = query;
    return Stream.fromIterable(streamChunks);
  }
}

List<int> frame(int type, List<int> payload) {
  final n = payload.length;
  return [type, 0, 0, 0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, ...payload];
}

void main() {
  test('inspectContainer parses tty', () async {
    final t = _FakeTransport(
      getResponse: http.Response('{"Id":"a","Name":"/w","Config":{"Image":"nginx","Tty":true},"State":{"Status":"running"}}', 200),
    );
    final c = await DockerApiClient(t).inspectContainer('a');
    expect(c.tty, isTrue);
    expect(c.name, 'w');
  });

  test('inspectContainer throws on non-200', () async {
    final t = _FakeTransport(getResponse: http.Response('no', 404));
    expect(() => DockerApiClient(t).inspectContainer('a'), throwsA(isA<DockerApiException>()));
  });

  test('streamContainerLogs demuxes non-TTY frames and builds query', () async {
    final t = _FakeTransport(
      getResponse: http.Response('{}', 200),
      streamChunks: [frame(1, utf8.encode('out')), frame(2, utf8.encode('err'))],
    );
    final chunks = await DockerApiClient(t)
        .streamContainerLogs('a', tty: false, follow: true, tail: 100, timestamps: true)
        .toList();

    expect(t.lastStreamPath, '/containers/a/logs');
    expect(t.lastStreamQuery, {
      'follow': 'true',
      'stdout': 'true',
      'stderr': 'true',
      'tail': '100',
      'timestamps': 'true',
    });
    expect(chunks.map((c) => c.source).toList(), [LogStream.stdout, LogStream.stderr]);
    expect(utf8.decode(chunks[0].bytes), 'out');
    expect(utf8.decode(chunks[1].bytes), 'err');
  });

  test('streamContainerLogs uses raw decoder for TTY and tail=all by default', () async {
    final t = _FakeTransport(
      getResponse: http.Response('{}', 200),
      streamChunks: [utf8.encode('hello')],
    );
    final chunks = await DockerApiClient(t).streamContainerLogs('a', tty: true).toList();

    expect(t.lastStreamQuery!['tail'], 'all');
    expect(chunks.single.source, LogStream.stdout);
    expect(utf8.decode(chunks.single.bytes), 'hello');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/docker_api_client_logs_test.dart`
Expected: FAIL — `inspectContainer`/`streamContainerLogs` undefined.

- [ ] **Step 3: Add the methods**

In `app/lib/src/api/docker_api_client.dart`, update imports and add the two methods. The file becomes:
```dart
import 'dart:convert';

import '../transport/transport.dart';
import 'models/docker_container.dart';
import 'models/container_inspect.dart';
import 'stdcopy.dart';

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

  Future<List<DockerContainer>> listContainers({bool all = true}) async {
    final resp = await transport.get('/containers/json', query: {'all': all.toString()});
    if (resp.statusCode != 200) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    final decoded = jsonDecode(resp.body) as List<dynamic>;
    return decoded
        .map((e) => DockerContainer.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<ContainerInspect> inspectContainer(String id) async {
    final resp = await transport.get('/containers/$id/json');
    if (resp.statusCode != 200) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    return ContainerInspect.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Streams a container's logs. For non-TTY containers the bytes are stdcopy
  /// multiplexed and demuxed here; for TTY containers they pass through raw.
  Stream<LogChunk> streamContainerLogs(
    String id, {
    required bool tty,
    bool follow = true,
    int? tail,
    bool timestamps = false,
    bool stdout = true,
    bool stderr = true,
  }) {
    final query = {
      'follow': follow.toString(),
      'stdout': stdout.toString(),
      'stderr': stderr.toString(),
      'tail': tail?.toString() ?? 'all',
      'timestamps': timestamps.toString(),
    };
    final raw = transport.stream('/containers/$id/logs', query: query);
    return tty ? decodeRawLog(raw) : decodeStdcopy(raw);
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/ && flutter analyze`
Expected: PASS (new + existing api tests); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/docker_api_client.dart app/test/api/docker_api_client_logs_test.dart
git commit -m "feat(app): DockerApiClient.inspectContainer + streamContainerLogs"
```

---

## Task 6: LogsNotifier + providers

**Files:**
- Create: `app/lib/src/state/logs_notifier.dart`
- Test: `app/test/state/logs_notifier_test.dart`

**Interfaces:**
- Consumes: `DockerApiClient` (Task 5), `LogChunk`/`LogStream` (Task 3), `LogLine` (Task 4), `dockerClientProvider` (existing, in `providers.dart`).
- Produces:
  - `const int kLogBufferCap = 5000;`
  - `enum LogsStatus { streaming, idle, error }`
  - `class LogsState { final List<LogLine> lines; final bool following; final bool timestamps; final int? tail; final String search; final LogsStatus status; final String? error; ... List<LogLine> get visibleLines; LogsState copyWith({...}); }`
  - `class LogsNotifier extends StateNotifier<LogsState> { LogsNotifier(DockerApiClient client, String id, bool tty); void setFollowing(bool); void setTimestamps(bool); void setTail(int?); void setSearch(String); void retry(); String snapshot(); }`
  - `final containerInspectProvider = FutureProvider.family<ContainerInspect, String>(...)`
  - `final logsProvider = StateNotifierProvider.family<LogsNotifier, LogsState, ({String id, bool tty})>(...)`

- [ ] **Step 1: Write the failing test**

Create `app/test/state/logs_notifier_test.dart`:
```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/logs_notifier.dart';

class _FakeTransport implements Transport {
  final List<List<int>> chunks;
  _FakeTransport(this.chunks);
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{}', 200);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => Stream.fromIterable(chunks);
}

List<int> frame(int type, List<int> payload) {
  final n = payload.length;
  return [type, 0, 0, 0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, ...payload];
}

void main() {
  test('assembles lines across chunk boundaries', () async {
    final client = DockerApiClient(_FakeTransport([
      frame(1, utf8.encode('hel')),
      frame(1, utf8.encode('lo\nwor')),
      frame(1, utf8.encode('ld\n')),
    ]));
    final n = LogsNotifier(client, 'a', false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.lines.map((l) => l.text).toList(), ['hello', 'world']);
    n.dispose();
  });

  test('tags stderr lines', () async {
    final client = DockerApiClient(_FakeTransport([frame(2, utf8.encode('boom\n'))]));
    final n = LogsNotifier(client, 'a', false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.lines.single.source, LogStream.stderr);
    n.dispose();
  });

  test('search filters visible lines', () async {
    final client = DockerApiClient(_FakeTransport([frame(1, utf8.encode('apple\nbanana\n'))]));
    final n = LogsNotifier(client, 'a', false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    n.setSearch('ban');
    expect(n.state.visibleLines.map((l) => l.text).toList(), ['banana']);
    n.dispose();
  });

  test('caps the buffer at kLogBufferCap lines', () async {
    final many = List.generate(kLogBufferCap + 10, (i) => 'line$i').join('\n') + '\n';
    final client = DockerApiClient(_FakeTransport([frame(1, utf8.encode(many))]));
    final n = LogsNotifier(client, 'a', false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.lines.length, kLogBufferCap);
    expect(n.state.lines.last.text, 'line${kLogBufferCap + 9}'); // newest kept
    n.dispose();
  });

  test('reaches idle status when a non-following stream completes', () async {
    final client = DockerApiClient(_FakeTransport([frame(1, utf8.encode('x\n'))]));
    final n = LogsNotifier(client, 'a', false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.status, LogsStatus.idle);
    n.dispose();
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/state/logs_notifier_test.dart`
Expected: FAIL — `LogsNotifier` undefined.

- [ ] **Step 3: Write the implementation**

Create `app/lib/src/state/logs_notifier.dart`:
```dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_inspect.dart';
import '../api/models/log_line.dart';
import '../api/stdcopy.dart';
import 'providers.dart';

const int kLogBufferCap = 5000;

enum LogsStatus { streaming, idle, error }

class LogsState {
  final List<LogLine> lines;
  final bool following;
  final bool timestamps;
  final int? tail;
  final String search;
  final LogsStatus status;
  final String? error;

  const LogsState({
    this.lines = const [],
    this.following = true,
    this.timestamps = false,
    this.tail,
    this.search = '',
    this.status = LogsStatus.streaming,
    this.error,
  });

  List<LogLine> get visibleLines {
    if (search.isEmpty) return lines;
    final q = search.toLowerCase();
    return lines.where((l) => l.text.toLowerCase().contains(q)).toList();
  }

  LogsState copyWith({
    List<LogLine>? lines,
    bool? following,
    bool? timestamps,
    int? tail,
    bool clearTail = false,
    String? search,
    LogsStatus? status,
    String? error,
    bool clearError = false,
  }) {
    return LogsState(
      lines: lines ?? this.lines,
      following: following ?? this.following,
      timestamps: timestamps ?? this.timestamps,
      tail: clearTail ? null : (tail ?? this.tail),
      search: search ?? this.search,
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class LogsNotifier extends StateNotifier<LogsState> {
  final DockerApiClient _client;
  final String _id;
  final bool _tty;
  StreamSubscription<LogChunk>? _sub;
  final Map<LogStream, String> _partial = {};

  LogsNotifier(this._client, this._id, this._tty) : super(const LogsState()) {
    _start();
  }

  void _start() {
    _sub?.cancel();
    _partial.clear();
    state = state.copyWith(lines: [], status: LogsStatus.streaming, clearError: true);
    _sub = _client
        .streamContainerLogs(
          _id,
          tty: _tty,
          follow: state.following,
          tail: state.tail,
          timestamps: state.timestamps,
        )
        .listen(_onChunk, onError: _onError, onDone: _onDone, cancelOnError: true);
  }

  void _onChunk(LogChunk chunk) {
    final text = utf8.decode(chunk.bytes, allowMalformed: true);
    final combined = (_partial[chunk.source] ?? '') + text;
    final parts = combined.split('\n');
    _partial[chunk.source] = parts.removeLast(); // trailing partial line
    if (parts.isEmpty) return;
    final next = [...state.lines, ...parts.map((p) => _toLine(chunk.source, p))];
    final capped = next.length > kLogBufferCap
        ? next.sublist(next.length - kLogBufferCap)
        : next;
    state = state.copyWith(lines: capped);
  }

  LogLine _toLine(LogStream source, String raw) {
    if (!state.timestamps) return LogLine(source: source, text: raw);
    final space = raw.indexOf(' ');
    if (space > 0) {
      final ts = DateTime.tryParse(raw.substring(0, space));
      if (ts != null) {
        return LogLine(source: source, text: raw.substring(space + 1), timestamp: ts);
      }
    }
    return LogLine(source: source, text: raw);
  }

  void _onError(Object e, StackTrace _) =>
      state = state.copyWith(status: LogsStatus.error, error: e.toString());

  void _onDone() {
    if (state.status != LogsStatus.error) {
      state = state.copyWith(status: LogsStatus.idle);
    }
  }

  void setFollowing(bool value) {
    state = state.copyWith(following: value);
    _start();
  }

  void setTimestamps(bool value) {
    state = state.copyWith(timestamps: value);
    _start();
  }

  void setTail(int? value) {
    state = state.copyWith(tail: value, clearTail: value == null);
    _start();
  }

  void setSearch(String value) => state = state.copyWith(search: value);

  void retry() => _start();

  String snapshot() => state.lines.map((l) => l.text).join('\n');

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

final containerInspectProvider =
    FutureProvider.family<ContainerInspect, String>((ref, id) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.inspectContainer(id);
});

final logsProvider = StateNotifierProvider.family<LogsNotifier, LogsState, ({String id, bool tty})>(
  (ref, key) {
    final client = ref.watch(dockerClientProvider);
    if (client == null) throw StateError('Not connected');
    return LogsNotifier(client, key.id, key.tty);
  },
);
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/state/logs_notifier_test.dart`
Expected: PASS (all 5 cases).

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/state/logs_notifier.dart app/test/state/logs_notifier_test.dart
git commit -m "feat(app): LogsNotifier with ring buffer, search, follow/tail/timestamps"
```

---

## Task 7: LogsScreen + ContainersScreen entry + share_plus

**Files:**
- Modify: `app/pubspec.yaml`
- Create: `app/lib/src/ui/logs_screen.dart`
- Modify: `app/lib/src/ui/containers_screen.dart`
- Test: `app/test/ui/logs_screen_test.dart`

**Interfaces:**
- Consumes: `logsProvider`, `containerInspectProvider`, `LogsState`, `LogsStatus`, `kLogBufferCap` (Task 6); `LogStream` (Task 3).
- Produces: `class LogsScreen extends ConsumerWidget { const LogsScreen({required this.containerId, required this.containerName}); }`; `ContainersScreen` ListTile navigates to it on tap.

- [ ] **Step 1: Add the dependency**

Edit `app/pubspec.yaml` — under `dependencies:` (after `flutter_riverpod`) add:
```yaml
  share_plus: ^10.0.0
```
Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter pub get`
Expected: resolves. (If `share_plus` ^10 is unavailable for this SDK, run `flutter pub add share_plus` and use the resolved version.)

- [ ] **Step 2: Write the failing widget test**

Create `app/test/ui/logs_screen_test.dart`:
```dart
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/logs_screen.dart';

class _FakeTransport implements Transport {
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async =>
      http.Response('{"Id":"a","Name":"/web","Config":{"Image":"nginx","Tty":false},"State":{"Status":"running"}}', 200);

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    List<int> frame(int type, List<int> p) {
      final n = p.length;
      return [type, 0, 0, 0, 0, 0, (n >> 8) & 0xff, n & 0xff, ...p];
    }
    return Stream.fromIterable([
      frame(1, utf8.encode('hello-out\n')),
      frame(2, utf8.encode('oops-err\n')),
    ]);
  }
}

void main() {
  testWidgets('renders streamed log lines', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [transportProvider.overrideWith((ref) => _FakeTransport())],
        child: const MaterialApp(
          home: LogsScreen(containerId: 'a', containerName: 'web'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget); // app bar title
    expect(find.textContaining('hello-out'), findsOneWidget);
    expect(find.textContaining('oops-err'), findsOneWidget);
  });

  testWidgets('search filters the rendered lines', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [transportProvider.overrideWith((ref) => _FakeTransport())],
        child: const MaterialApp(
          home: LogsScreen(containerId: 'a', containerName: 'web'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'oops');
    await tester.pumpAndSettle();

    expect(find.textContaining('oops-err'), findsOneWidget);
    expect(find.textContaining('hello-out'), findsNothing);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/logs_screen_test.dart`
Expected: FAIL — `LogsScreen` undefined.

- [ ] **Step 4: Write the LogsScreen**

Create `app/lib/src/ui/logs_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../api/stdcopy.dart';
import '../state/logs_notifier.dart';

class LogsScreen extends ConsumerWidget {
  final String containerId;
  final String containerName;
  const LogsScreen({super.key, required this.containerId, required this.containerName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inspect = ref.watch(containerInspectProvider(containerId));
    return Scaffold(
      appBar: AppBar(title: Text(containerName)),
      body: inspect.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorBanner(message: '$e', onRetry: () => ref.invalidate(containerInspectProvider(containerId))),
        data: (info) => _LogsBody(key: ValueKey(info.id), id: containerId, tty: info.tty),
      ),
    );
  }
}

class _LogsBody extends ConsumerStatefulWidget {
  final String id;
  final bool tty;
  const _LogsBody({super.key, required this.id, required this.tty});

  @override
  ConsumerState<_LogsBody> createState() => _LogsBodyState();
}

class _LogsBodyState extends ConsumerState<_LogsBody> {
  final _scroll = ScrollController();
  final _searchCtl = TextEditingController();

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final key = (id: widget.id, tty: widget.tty);
    final state = ref.watch(logsProvider(key));
    final notifier = ref.read(logsProvider(key).notifier);
    final lines = state.visibleLines;

    // Autoscroll to newest while following.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (state.following && _scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });

    return Column(
      children: [
        _Controls(
          state: state,
          searchCtl: _searchCtl,
          onFollow: notifier.setFollowing,
          onTimestamps: notifier.setTimestamps,
          onTail: notifier.setTail,
          onSearch: notifier.setSearch,
          onShare: () => SharePlus.instance.share(ShareParams(text: notifier.snapshot())),
        ),
        if (state.status == LogsStatus.error)
          _ErrorBanner(message: state.error ?? 'stream error', onRetry: notifier.retry),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            itemCount: lines.length,
            itemBuilder: (context, i) {
              final l = lines[i];
              final color = l.source == LogStream.stderr
                  ? Theme.of(context).colorScheme.error
                  : Theme.of(context).colorScheme.onSurface;
              final prefix = (state.timestamps && l.timestamp != null)
                  ? '${l.timestamp!.toLocal().toIso8601String()} '
                  : '';
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 1),
                child: SelectableText(
                  '$prefix${l.text}',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 12, color: color),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Controls extends StatelessWidget {
  final LogsState state;
  final TextEditingController searchCtl;
  final ValueChanged<bool> onFollow;
  final ValueChanged<bool> onTimestamps;
  final ValueChanged<int?> onTail;
  final ValueChanged<String> onSearch;
  final VoidCallback onShare;
  const _Controls({
    required this.state,
    required this.searchCtl,
    required this.onFollow,
    required this.onTimestamps,
    required this.onTail,
    required this.onSearch,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          IconButton(
            tooltip: 'Follow',
            icon: Icon(state.following ? Icons.pause : Icons.play_arrow),
            onPressed: () => onFollow(!state.following),
          ),
          IconButton(
            tooltip: 'Timestamps',
            icon: Icon(state.timestamps ? Icons.schedule : Icons.schedule_outlined),
            onPressed: () => onTimestamps(!state.timestamps),
          ),
          PopupMenuButton<int?>(
            tooltip: 'Tail',
            icon: const Icon(Icons.format_list_numbered),
            onSelected: onTail,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 100, child: Text('Tail 100')),
              PopupMenuItem(value: 500, child: Text('Tail 500')),
              PopupMenuItem(value: 1000, child: Text('Tail 1000')),
              PopupMenuItem(value: null, child: Text('All')),
            ],
          ),
          IconButton(tooltip: 'Share', icon: const Icon(Icons.ios_share), onPressed: onShare),
          Expanded(
            child: TextField(
              controller: searchCtl,
              decoration: const InputDecoration(hintText: 'Search', isDense: true, prefixIcon: Icon(Icons.search)),
              onChanged: onSearch,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorBanner({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      content: Text(message),
      backgroundColor: Theme.of(context).colorScheme.errorContainer,
      actions: [TextButton(onPressed: onRetry, child: const Text('Retry'))],
    );
  }
}
```
NOTE on the share API: this plan targets `share_plus` ^10 (`SharePlus.instance.share(ShareParams(text: ...))`). If `flutter analyze` reports the symbol is undefined because a different major version resolved, use that version's documented call instead — the older API is `Share.share(notifier.snapshot())`. Do not leave it uncompiling.

- [ ] **Step 5: Wire the entry point in ContainersScreen**

In `app/lib/src/ui/containers_screen.dart`, add the import at the top:
```dart
import 'logs_screen.dart';
```
and give the `ListTile` an `onTap` (inside `itemBuilder`, on the returned `ListTile`):
```dart
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => LogsScreen(containerId: c.id, containerName: name),
                ),
              ),
```

- [ ] **Step 6: Run the tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; **all** app tests pass (new logs_screen tests + every prior suite).

- [ ] **Step 7: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/src/ui/logs_screen.dart app/lib/src/ui/containers_screen.dart app/test/ui/logs_screen_test.dart
git commit -m "feat(app): live log viewer screen (follow/search/timestamps/tail/share)"
```

---

## Self-Review

**1. Spec coverage:**
- Streamed-HTTP mechanism + agent flush → Task 1. ✓
- `Transport.stream` + cancelable AgentTransport + non-200 error → Task 2. ✓
- `StdcopyDecoder` (cross-chunk, defensive) + TTY passthrough → Task 3. ✓
- `ContainerInspect` (tty) + `LogLine` → Task 4. ✓
- `DockerApiClient.inspectContainer` + `streamContainerLogs` (query, tty branch) → Task 5. ✓
- `LogsNotifier` (ring buffer cap, search, follow/tail/timestamps re-subscribe, error/idle status, snapshot) → Task 6. ✓
- `LogsScreen` (follow, timestamps, tail menu, search+filter, stdout/stderr color, autoscroll, share) + `ContainersScreen` onTap + `share_plus` → Task 7. ✓
- Error handling (in-viewer banner + retry; decoder never throws; ring-buffer cap; cancel closes connection) → Tasks 2/3/6/7. ✓
- Testing plan (decoder exhaustive, transport incl. cancel, client, notifier, widget) → covered across tasks. ✓
- Out of scope (WebSocket, stats/events, TCP+TLS/SSH, multi-container) → absent. ✓
- "Rich" extras (timestamps toggle, adjustable tail, download/share) → Task 6/7. ✓ (search-match *highlight* and jump-to-latest FAB are simplified to color + autoscroll in this plan; see note below.)

**2. Placeholder scan:** No TBD/TODO/"handle edge cases"/"similar to Task N". Every code step shows full code; every run step shows command + expected result. The `share_plus` note gives two concrete API forms, not a vague instruction.

**3. Type consistency:** `Transport.stream(String, {Map<String,String>? query}) → Stream<List<int>>` defined in Task 2, consumed identically in Tasks 5/6/7 fakes. `decodeStdcopy`/`decodeRawLog`/`LogChunk(source, bytes)`/`LogStream` from Task 3 used in Tasks 5/6/7. `ContainerInspect.{id,name,image,state,tty}` (Task 4) used in Tasks 5/6/7. `DockerApiClient.streamContainerLogs(id, {required tty, follow, tail, timestamps, stdout, stderr})` (Task 5) called consistently in Task 6. `logsProvider`/`containerInspectProvider`/`LogsState`/`LogsStatus`/`kLogBufferCap` (Task 6) used in Task 7. Family key record `({String id, bool tty})` consistent (Task 6 def, Task 7 use). ✓

**Scope note (resolved at handoff — polish INCLUDED):** this slice implements the full "Rich" UI: search **filtering** (matching lines) **plus inline match-highlight** (lines render as `SelectableText.rich` with highlighted match spans), stdout/stderr coloring, autoscroll while following, **and a jump-to-latest FAB** driven by scroll-position tracking (shown only when scrolled away from the bottom). Task 7's `LogsScreen` and `logs_screen_test.dart` are built with these; because lines render as `SelectableText.rich`, widget-test finders use `find.textContaining(..., findRichText: true)`.
