# Phase 1C-2 — Images + Top-Level Navigation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Image management (list / detail+history / pull-with-live-progress / tag / remove / prune) and the app's first top-level navigation (bottom-nav HomeScreen: Containers | Images).

**Architecture:** App-only. Add a streaming-POST transport primitive, image models, `DockerApiClient` image methods, and four screens, behind a `HomeScreen` bottom-nav bar.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `http` (all existing).

## Global Constraints

- **App-only slice:** no agent changes. All calls go through `DockerApiClient` over `Transport`.
- **Streaming POST:** pull uses `Transport.postStream` (cancelable streamed POST) — NOT the GET-only `stream`.
- **Status handling:** `DockerApiException(statusCode, body)` on non-success. Success codes: listImages/inspect/history/prune/remove = `200`; tag = `201`.
- **Pull progress:** `/images/create` is parsed as **newline-delimited JSON**; a line that fails to decode is skipped (never crash). In-stream `{"error":...}` (HTTP stays 200) becomes a `PullEvent.error`.
- **Navigation:** `HomeScreen` is a `Scaffold` (no app bar) with a `BottomNavigationBar` + `IndexedStack([ContainersScreen(), ImagesScreen()])`; `ConnectionScreen` lands on `HomeScreen`.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"`.
- **Discipline:** TDD, DRY, YAGNI, frequent commits, commit messages with NO `Co-Authored-By` trailer. Repo local/private on a feature branch.

---

## File Structure

```
app/lib/src/transport/transport.dart            # + postStream
app/lib/src/transport/agent_transport.dart       # extract _openStream; + postStream
app/lib/src/api/models/docker_image.dart          # DockerImage
app/lib/src/api/models/image_detail.dart          # ImageDetail + ImageHistoryLayer
app/lib/src/api/models/pull_event.dart            # PullEvent
app/lib/src/api/docker_api_client.dart            # + 7 image methods
app/lib/src/state/providers.dart                  # + images providers
app/lib/src/ui/pull_sheet.dart                    # PullSheet
app/lib/src/ui/image_detail_screen.dart           # ImageDetailScreen
app/lib/src/ui/images_screen.dart                 # ImagesScreen
app/lib/src/ui/home_screen.dart                   # HomeScreen (bottom nav)
app/lib/src/ui/connection_screen.dart             # land on HomeScreen
app/test/...                                        # mirrors the above
# + postStream stub added to existing Transport fakes (Task 1)
```

---

## Task 1: Transport.postStream

**Files:**
- Modify: `app/lib/src/transport/transport.dart`, `app/lib/src/transport/agent_transport.dart`
- Modify (stubs): all existing Transport fakes (see Step 5)
- Test: `app/test/transport/agent_transport_post_stream_test.dart`

**Interfaces:**
- Produces: `Transport.postStream(String path, {Map<String,String>? query, Object? body}) → Stream<List<int>>`; `AgentTransport` implements it (cancelable streamed POST, JSON body when given).

- [ ] **Step 1: Write the failing test**

Create `app/test/transport/agent_transport_post_stream_test.dart`:
```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/agent_transport.dart';

class _SpyClient extends http.BaseClient {
  final Stream<List<int>> body;
  final int status;
  http.BaseRequest? lastRequest;
  String? lastBody;
  _SpyClient(this.body, {this.status = 200});
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    if (request is http.Request) lastBody = request.body;
    return http.StreamedResponse(body, status);
  }
}

void main() {
  test('postStream POSTs with bearer + body and yields bytes', () async {
    final spy = _SpyClient(Stream.fromIterable([
      [1, 2],
      [3],
    ]));
    final t = AgentTransport(
      baseUri: Uri.parse('http://h:8080'),
      token: 'secret',
      streamClientFactory: () => spy,
    );

    final bytes = await t
        .postStream('/images/create', query: {'fromImage': 'nginx'}, body: {'k': 'v'})
        .expand((c) => c)
        .toList();

    expect(bytes, [1, 2, 3]);
    expect(spy.lastRequest!.method, 'POST');
    expect(spy.lastRequest!.headers['Authorization'], 'Bearer secret');
    expect(spy.lastRequest!.url.queryParameters['fromImage'], 'nginx');
    expect(jsonDecode(spy.lastBody!), {'k': 'v'});
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/agent_transport_post_stream_test.dart`
Expected: FAIL — `postStream` not defined.

- [ ] **Step 3: Add to the interface**

In `app/lib/src/transport/transport.dart`, add to `abstract class Transport` (after `delete`):
```dart
  /// Streamed POST (e.g. image pull/build/load progress). Cancel closes it.
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body});
```

- [ ] **Step 4: Refactor AgentTransport to share streaming, add postStream**

In `app/lib/src/transport/agent_transport.dart`, ensure `import 'dart:convert';` is present, then REPLACE the existing `stream(...)` method with this `_openStream` helper + the two public methods:
```dart
  Stream<List<int>> _openStream(http.Request request) {
    final client = _streamClientFactory();
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    var clientClosed = false;
    void closeClient() {
      if (!clientClosed) {
        clientClosed = true;
        client.close();
      }
    }

    controller.onListen = () async {
      try {
        request.headers['Authorization'] = 'Bearer $token';
        final response = await client.send(request);
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          controller.addError(TransportException(response.statusCode, body));
          await controller.close();
          closeClient();
          return;
        }
        sub = response.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: () async {
            await controller.close();
            closeClient();
          },
          cancelOnError: true,
        );
      } catch (e) {
        controller.addError(e);
        await controller.close();
        closeClient();
      }
    };
    controller.onCancel = () async {
      await sub?.cancel();
      closeClient();
    };
    return controller.stream;
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    return _openStream(http.Request('GET', uri));
  }

  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    final request = http.Request('POST', uri);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = body is String ? body : jsonEncode(body);
    }
    return _openStream(request);
  }
```
(This preserves `stream`'s behavior — the existing `agent_transport_stream_test.dart` must still pass.)

- [ ] **Step 5: Add the `postStream` stub to every existing Transport fake**

Add this override to each fake class implementing `Transport`:
```dart
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) =>
      const Stream.empty();
```
Fakes: `_FakeTransport` in `docker_api_client_test.dart`, `docker_api_client_logs_test.dart`, `docker_api_client_exec_test.dart`, `docker_api_client_actions_test.dart`, `logs_screen_test.dart`, `exec_screen_test.dart`, `container_detail_screen_test.dart`; `_FakeTransport` AND `_ControllerTransport` in `logs_notifier_test.dart`; `_ExecFakeTransport` in `exec_session_controller_test.dart`.

- [ ] **Step 6: Run analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; all tests pass (new postStream test + the existing stream test + every prior suite).

- [ ] **Step 7: Commit**

```bash
git add app/lib/src/transport app/test
git commit -m "feat(app): Transport.postStream (cancelable streamed POST)"
```

---

## Task 2: Image models

**Files:**
- Create: `app/lib/src/api/models/docker_image.dart`, `app/lib/src/api/models/image_detail.dart`, `app/lib/src/api/models/pull_event.dart`
- Test: `app/test/api/models/docker_image_test.dart`, `app/test/api/models/image_detail_test.dart`, `app/test/api/models/pull_event_test.dart`

**Interfaces:**
- Produces:
  - `class DockerImage { final String id; final List<String> repoTags; final int size; final int created; factory DockerImage.fromJson(Map); }`
  - `class ImageHistoryLayer { final String id; final int created; final String createdBy; final int size; final List<String> tags; factory ImageHistoryLayer.fromJson(Map); }`
  - `class ImageDetail { final String id; final List<String> repoTags; final String architecture; final String os; final int size; final String created; final List<String> env; final List<String> exposedPorts; factory ImageDetail.fromJson(Map); }`
  - `class PullEvent { final String status; final String? id; final int? current; final int? total; final String? error; factory PullEvent.fromJson(Map); }`

- [ ] **Step 1: Write the failing tests**

Create `app/test/api/models/docker_image_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_image.dart';

void main() {
  test('parses /images/json element', () {
    final i = DockerImage.fromJson({
      'Id': 'sha256:abc',
      'RepoTags': ['nginx:latest', 'nginx:1.27'],
      'Size': 1234,
      'Created': 1700000000,
    });
    expect(i.id, 'sha256:abc');
    expect(i.repoTags, ['nginx:latest', 'nginx:1.27']);
    expect(i.size, 1234);
    expect(i.created, 1700000000);
  });

  test('tolerates null RepoTags', () {
    final i = DockerImage.fromJson({'Id': 'x', 'Size': 0, 'Created': 0});
    expect(i.repoTags, isEmpty);
  });
}
```

Create `app/test/api/models/image_detail_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/image_detail.dart';

void main() {
  test('ImageDetail parses /images/{id}/json', () {
    final d = ImageDetail.fromJson({
      'Id': 'sha256:abc',
      'RepoTags': ['nginx:latest'],
      'Architecture': 'amd64',
      'Os': 'linux',
      'Size': 5000,
      'Created': '2026-01-02T03:04:05Z',
      'Config': {'Env': ['A=1'], 'ExposedPorts': {'80/tcp': {}, '443/tcp': {}}},
    });
    expect(d.architecture, 'amd64');
    expect(d.os, 'linux');
    expect(d.env, ['A=1']);
    expect(d.exposedPorts, containsAll(['80/tcp', '443/tcp']));
    expect(d.created, '2026-01-02T03:04:05Z');
  });

  test('ImageHistoryLayer parses a /history element', () {
    final l = ImageHistoryLayer.fromJson({
      'Id': 'sha256:def',
      'Created': 1700000000,
      'CreatedBy': '/bin/sh -c #(nop) CMD',
      'Size': 42,
      'Tags': ['nginx:latest'],
    });
    expect(l.id, 'sha256:def');
    expect(l.created, 1700000000);
    expect(l.createdBy, contains('CMD'));
    expect(l.size, 42);
    expect(l.tags, ['nginx:latest']);
  });

  test('ImageHistoryLayer tolerates null Tags', () {
    final l = ImageHistoryLayer.fromJson({'Id': 'x', 'Created': 0, 'CreatedBy': '', 'Size': 0});
    expect(l.tags, isEmpty);
  });
}
```

Create `app/test/api/models/pull_event_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/pull_event.dart';

void main() {
  test('parses a progress event', () {
    final e = PullEvent.fromJson({
      'status': 'Downloading',
      'id': 'abc',
      'progressDetail': {'current': 100, 'total': 500},
    });
    expect(e.status, 'Downloading');
    expect(e.id, 'abc');
    expect(e.current, 100);
    expect(e.total, 500);
    expect(e.error, isNull);
  });

  test('parses an error event', () {
    final e = PullEvent.fromJson({'error': 'manifest unknown', 'errorDetail': {'message': 'manifest unknown'}});
    expect(e.error, 'manifest unknown');
  });

  test('tolerates an event with only status', () {
    final e = PullEvent.fromJson({'status': 'Pull complete', 'id': 'abc'});
    expect(e.current, isNull);
    expect(e.total, isNull);
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/docker_image_test.dart test/api/models/image_detail_test.dart test/api/models/pull_event_test.dart`
Expected: FAIL — models undefined.

- [ ] **Step 3: Write the models**

Create `app/lib/src/api/models/docker_image.dart`:
```dart
/// A Docker image as returned by `GET /images/json`.
class DockerImage {
  final String id;
  final List<String> repoTags;
  final int size;
  final int created;

  const DockerImage({required this.id, required this.repoTags, required this.size, required this.created});

  factory DockerImage.fromJson(Map<String, dynamic> json) => DockerImage(
        id: json['Id'] as String? ?? '',
        repoTags: (json['RepoTags'] as List?)?.cast<String>() ?? const [],
        size: (json['Size'] as num?)?.toInt() ?? 0,
        created: (json['Created'] as num?)?.toInt() ?? 0,
      );
}
```

Create `app/lib/src/api/models/image_detail.dart`:
```dart
/// One layer from `GET /images/{id}/history`.
class ImageHistoryLayer {
  final String id;
  final int created;
  final String createdBy;
  final int size;
  final List<String> tags;

  const ImageHistoryLayer({
    required this.id,
    required this.created,
    required this.createdBy,
    required this.size,
    required this.tags,
  });

  factory ImageHistoryLayer.fromJson(Map<String, dynamic> json) => ImageHistoryLayer(
        id: json['Id'] as String? ?? '',
        created: (json['Created'] as num?)?.toInt() ?? 0,
        createdBy: json['CreatedBy'] as String? ?? '',
        size: (json['Size'] as num?)?.toInt() ?? 0,
        tags: (json['Tags'] as List?)?.cast<String>() ?? const [],
      );
}

/// Subset of `GET /images/{id}/json`.
class ImageDetail {
  final String id;
  final List<String> repoTags;
  final String architecture;
  final String os;
  final int size;
  final String created;
  final List<String> env;
  final List<String> exposedPorts;

  const ImageDetail({
    required this.id,
    required this.repoTags,
    required this.architecture,
    required this.os,
    required this.size,
    required this.created,
    required this.env,
    required this.exposedPorts,
  });

  factory ImageDetail.fromJson(Map<String, dynamic> json) {
    final config = (json['Config'] as Map<String, dynamic>?) ?? const {};
    final exposed = (config['ExposedPorts'] as Map<String, dynamic>?)?.keys.toList() ?? const <String>[];
    return ImageDetail(
      id: json['Id'] as String? ?? '',
      repoTags: (json['RepoTags'] as List?)?.cast<String>() ?? const [],
      architecture: json['Architecture'] as String? ?? '',
      os: json['Os'] as String? ?? '',
      size: (json['Size'] as num?)?.toInt() ?? 0,
      created: json['Created'] as String? ?? '',
      env: (config['Env'] as List?)?.cast<String>() ?? const [],
      exposedPorts: exposed,
    );
  }
}
```

Create `app/lib/src/api/models/pull_event.dart`:
```dart
/// One JSON line from `POST /images/create` progress.
class PullEvent {
  final String status;
  final String? id;
  final int? current;
  final int? total;
  final String? error;

  const PullEvent({this.status = '', this.id, this.current, this.total, this.error});

  factory PullEvent.fromJson(Map<String, dynamic> json) {
    final detail = json['progressDetail'] as Map<String, dynamic>?;
    return PullEvent(
      status: json['status'] as String? ?? '',
      id: json['id'] as String?,
      current: (detail?['current'] as num?)?.toInt(),
      total: (detail?['total'] as num?)?.toInt(),
      error: json['error'] as String?,
    );
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/models/docker_image.dart app/lib/src/api/models/image_detail.dart app/lib/src/api/models/pull_event.dart app/test/api/models/docker_image_test.dart app/test/api/models/image_detail_test.dart app/test/api/models/pull_event_test.dart
git commit -m "feat(app): image models (DockerImage, ImageDetail, ImageHistoryLayer, PullEvent)"
```

---

## Task 3: DockerApiClient — image methods

**Files:**
- Modify: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/docker_api_client_images_test.dart`

**Interfaces:**
- Consumes: `Transport` (Task 1), image models (Task 2).
- Produces on `DockerApiClient`: `listImages()`, `inspectImage(id)`, `imageHistory(id)`, `pullImage(image,{tag})`, `tagImage(id,{repo,tag})`, `removeImage(id,{force,noprune})`, `pruneImages({danglingOnly})`.

- [ ] **Step 1: Write the failing test**

Create `app/test/api/docker_api_client_images_test.dart`:
```dart
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _Rec {
  final String verb, path;
  final Map<String, String>? query;
  _Rec(this.verb, this.path, this.query);
}

class _FakeTransport implements Transport {
  final List<_Rec> calls = [];
  http.Response getResponse = http.Response('[]', 200);
  int postStatus = 200;
  int deleteStatus = 200;
  List<List<int>> pullChunks = const [];

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    calls.add(_Rec('get', path, query));
    return getResponse;
  }
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    calls.add(_Rec('post', path, query));
    return http.Response('', postStatus);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    calls.add(_Rec('delete', path, query));
    return http.Response('', deleteStatus);
  }
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) {
    calls.add(_Rec('postStream', path, query));
    return Stream.fromIterable(pullChunks);
  }
}

void main() {
  test('listImages parses the array', () async {
    final t = _FakeTransport()
      ..getResponse = http.Response('[{"Id":"a","RepoTags":["nginx:latest"],"Size":1,"Created":2}]', 200);
    final images = await DockerApiClient(t).listImages();
    expect(images.single.repoTags, ['nginx:latest']);
    expect(t.calls.single.path, '/images/json');
  });

  test('pullImage parses newline-delimited progress and queries fromImage+tag', () async {
    final t = _FakeTransport()
      ..pullChunks = [
        utf8.encode('{"status":"Pulling fs layer","id":"l1"}\n{"status":"Down'),
        utf8.encode('loading","id":"l1","progressDetail":{"current":5,"total":10}}\n'),
        utf8.encode('{"error":"nope"}\n'),
      ];
    final events = await DockerApiClient(t).pullImage('nginx', tag: '1.27').toList();

    expect(t.calls.last.path, '/images/create');
    expect(t.calls.last.query, {'fromImage': 'nginx', 'tag': '1.27'});
    expect(events.map((e) => e.status).toList(), ['Pulling fs layer', 'Downloading', '']);
    expect(events[1].current, 5);
    expect(events.last.error, 'nope');
  });

  test('tagImage posts repo+tag (201)', () async {
    final t = _FakeTransport()..postStatus = 201;
    await DockerApiClient(t).tagImage('a', repo: 'myrepo', tag: 'v1');
    expect(t.calls.last.path, '/images/a/tag');
    expect(t.calls.last.query, {'repo': 'myrepo', 'tag': 'v1'});
  });

  test('removeImage deletes with force+noprune', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).removeImage('a', force: true, noprune: true);
    expect(t.calls.last.verb, 'delete');
    expect(t.calls.last.path, '/images/a');
    expect(t.calls.last.query, {'force': 'true', 'noprune': 'true'});
  });

  test('pruneImages sends dangling filter', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).pruneImages(danglingOnly: false);
    expect(t.calls.last.path, '/images/prune');
    expect(t.calls.last.query, {'filters': '{"dangling":["false"]}'});
  });

  test('tagImage throws on non-201', () async {
    final t = _FakeTransport()..postStatus = 409;
    expect(() => DockerApiClient(t).tagImage('a', repo: 'r'), throwsA(isA<DockerApiException>()));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/docker_api_client_images_test.dart`
Expected: FAIL — image methods undefined.

- [ ] **Step 3: Add the methods**

In `app/lib/src/api/docker_api_client.dart`, add imports `import 'models/docker_image.dart';` and `import 'models/image_detail.dart';` and `import 'models/pull_event.dart';`, then append inside `DockerApiClient`:
```dart
  Future<List<DockerImage>> listImages() async {
    final resp = await transport.get('/images/json');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as List).map((e) => DockerImage.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ImageDetail> inspectImage(String id) async {
    final resp = await transport.get('/images/$id/json');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return ImageDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<List<ImageHistoryLayer>> imageHistory(String id) async {
    final resp = await transport.get('/images/$id/history');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as List).map((e) => ImageHistoryLayer.fromJson(e as Map<String, dynamic>)).toList();
  }

  Stream<PullEvent> pullImage(String image, {String tag = 'latest'}) async* {
    final raw = transport.postStream('/images/create', query: {'fromImage': image, 'tag': tag});
    var buffer = '';
    await for (final chunk in raw) {
      buffer += utf8.decode(chunk, allowMalformed: true);
      final lines = buffer.split('\n');
      buffer = lines.removeLast();
      for (final line in lines) {
        final ev = _parsePullLine(line);
        if (ev != null) yield ev;
      }
    }
    final ev = _parsePullLine(buffer);
    if (ev != null) yield ev;
  }

  PullEvent? _parsePullLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return null;
    try {
      return PullEvent.fromJson(jsonDecode(t) as Map<String, dynamic>);
    } catch (_) {
      return null; // skip a fragment that isn't a complete JSON object
    }
  }

  Future<void> tagImage(String id, {required String repo, String tag = 'latest'}) async =>
      _ensure(await transport.post('/images/$id/tag', query: {'repo': repo, 'tag': tag}), ok: const {201});

  Future<void> removeImage(String id, {bool force = false, bool noprune = false}) async =>
      _ensure(await transport.delete('/images/$id', query: {'force': '$force', 'noprune': '$noprune'}), ok: const {200});

  Future<void> pruneImages({bool danglingOnly = true}) async => _ensure(
        await transport.post('/images/prune', query: {'filters': '{"dangling":["${danglingOnly ? 'true' : 'false'}"]}'}),
        ok: const {200},
      );
```

- [ ] **Step 4: Run the tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/ && flutter analyze`
Expected: PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/docker_api_client.dart app/test/api/docker_api_client_images_test.dart
git commit -m "feat(app): DockerApiClient image methods (list/inspect/history/pull/tag/remove/prune)"
```

---

## Task 4: PullSheet

**Files:**
- Create: `app/lib/src/ui/pull_sheet.dart`
- Test: `app/test/ui/pull_sheet_test.dart`

**Interfaces:**
- Consumes: `DockerApiClient.pullImage` (Task 3), `PullEvent` (Task 2), `dockerClientProvider`.
- Produces: `class PullSheet extends ConsumerStatefulWidget { const PullSheet({super.key}); }`.

- [ ] **Step 1: Write the failing widget test**

Create `app/test/ui/pull_sheet_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/pull_sheet.dart';

class _FakeTransport implements Transport {
  final List<int> pullBytes;
  Map<String, String>? lastPullQuery;
  _FakeTransport(this.pullBytes);
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 200);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) {
    lastPullQuery = query;
    return Stream.value(pullBytes);
  }
}

void main() {
  testWidgets('streams progress for a pulled ref', (tester) async {
    final t = _FakeTransport(utf8.encode('{"status":"Pulling fs layer","id":"l1"}\n{"status":"Pull complete","id":"l1"}\n'));
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: PullSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nginx:1.27');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Pull'));
    await tester.pumpAndSettle();

    expect(t.lastPullQuery, {'fromImage': 'nginx', 'tag': '1.27'});
    expect(find.textContaining('Pull complete'), findsWidgets);
  });

  testWidgets('surfaces an error event', (tester) async {
    final t = _FakeTransport(utf8.encode('{"error":"manifest unknown"}\n'));
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: PullSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Pull'));
    await tester.pumpAndSettle();

    expect(find.textContaining('manifest unknown'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/pull_sheet_test.dart`
Expected: FAIL — `PullSheet` undefined.

- [ ] **Step 3: Write PullSheet**

Create `app/lib/src/ui/pull_sheet.dart`:
```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/pull_event.dart';
import '../state/providers.dart';

/// Splits an image ref into (image, tag); a colon after the last slash is the tag.
(String, String) parseImageRef(String ref) {
  final slash = ref.lastIndexOf('/');
  final colon = ref.lastIndexOf(':');
  if (colon > slash && colon != -1) {
    return (ref.substring(0, colon), ref.substring(colon + 1));
  }
  return (ref, 'latest');
}

class PullSheet extends ConsumerStatefulWidget {
  const PullSheet({super.key});

  @override
  ConsumerState<PullSheet> createState() => _PullSheetState();
}

class _PullSheetState extends ConsumerState<PullSheet> {
  final _ref = TextEditingController();
  StreamSubscription<PullEvent>? _sub;
  final Map<String, PullEvent> _layers = {};
  String _overall = '';
  String? _error;
  bool _running = false;
  bool _done = false;

  @override
  void dispose() {
    _sub?.cancel();
    _ref.dispose();
    super.dispose();
  }

  void _pull() {
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    final (image, tag) = parseImageRef(_ref.text.trim());
    setState(() {
      _layers.clear();
      _overall = 'Pulling $image:$tag…';
      _error = null;
      _running = true;
      _done = false;
    });
    _sub?.cancel();
    _sub = client.pullImage(image, tag: tag).listen((e) {
      setState(() {
        if (e.error != null) {
          _error = e.error;
        } else if (e.id != null && e.id!.isNotEmpty) {
          _layers[e.id!] = e;
        } else {
          _overall = e.status;
        }
      });
    }, onError: (e) {
      setState(() {
        _error = '$e';
        _running = false;
      });
    }, onDone: () {
      setState(() {
        _running = false;
        _done = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final layers = _layers.values.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Pull image')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(children: [
              Expanded(child: TextField(
                controller: _ref,
                decoration: const InputDecoration(labelText: 'Image (e.g. nginx:latest)'),
              )),
              const SizedBox(width: 8),
              ElevatedButton(onPressed: _running ? null : _pull, child: const Text('Pull')),
            ]),
            const SizedBox(height: 12),
            if (_overall.isNotEmpty) Text(_overall, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Error: $_error', style: TextStyle(color: Theme.of(context).colorScheme.error)),
              ),
            if (_done && _error == null)
              const Padding(padding: EdgeInsets.only(top: 8), child: Text('Pull complete')),
            const SizedBox(height: 12),
            Expanded(
              child: ListView.builder(
                itemCount: layers.length,
                itemBuilder: (context, i) {
                  final l = layers[i];
                  final progress = (l.total != null && l.total! > 0 && l.current != null)
                      ? (l.current! / l.total!).clamp(0.0, 1.0)
                      : null;
                  return ListTile(
                    dense: true,
                    title: Text('${l.id}: ${l.status}'),
                    subtitle: progress == null ? null : LinearProgressIndicator(value: progress),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run the widget test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/pull_sheet_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/ui/pull_sheet.dart app/test/ui/pull_sheet_test.dart
git commit -m "feat(app): PullSheet with live streamed pull progress"
```

---

## Task 5: ImageDetailScreen + image providers

**Files:**
- Modify: `app/lib/src/state/providers.dart`
- Create: `app/lib/src/ui/image_detail_screen.dart`
- Test: `app/test/ui/image_detail_screen_test.dart`

**Interfaces:**
- Consumes: `inspectImage`/`imageHistory`/`tagImage`/`removeImage` (Task 3), `ImageDetail`/`ImageHistoryLayer` (Task 2), `dockerClientProvider`.
- Produces: `imageDetailProvider`, `imageHistoryProvider` (FutureProvider.family by id); `class ImageDetailScreen extends ConsumerWidget { const ImageDetailScreen({required this.imageId, required this.title}); }`.

- [ ] **Step 1: Add the providers**

In `app/lib/src/state/providers.dart`, add `import '../api/models/image_detail.dart';` and:
```dart
final imageDetailProvider = FutureProvider.family<ImageDetail, String>((ref, id) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.inspectImage(id);
});

final imageHistoryProvider = FutureProvider.family<List<ImageHistoryLayer>, String>((ref, id) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.imageHistory(id);
});
```

- [ ] **Step 2: Write the failing widget test**

Create `app/test/ui/image_detail_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/image_detail_screen.dart';

class _FakeTransport implements Transport {
  final List<String> deletes = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path.endsWith('/history')) {
      return http.Response('[{"Id":"l1","Created":0,"CreatedBy":"RUN apt-get","Size":10,"Tags":[]}]', 200);
    }
    return http.Response('{"Id":"sha256:abc","RepoTags":["nginx:latest"],"Architecture":"amd64","Os":"linux","Size":100,"Created":"2026-01-02T03:04:05Z","Config":{"Env":[],"ExposedPorts":{"80/tcp":{}}}}', 200);
  }
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('', 201);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    deletes.add(path);
    return http.Response('', 200);
  }
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  testWidgets('renders inspect + history and offers Remove', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ImageDetailScreen(imageId: 'sha256:abc', title: 'nginx:latest')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('nginx:latest'), findsOneWidget); // app bar title
    expect(find.textContaining('amd64'), findsWidgets);
    expect(find.textContaining('RUN apt-get'), findsWidgets); // history layer
    expect(find.widgetWithText(ElevatedButton, 'Remove'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/image_detail_screen_test.dart`
Expected: FAIL — `ImageDetailScreen` undefined.

- [ ] **Step 4: Write ImageDetailScreen**

Create `app/lib/src/ui/image_detail_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

class ImageDetailScreen extends ConsumerWidget {
  final String imageId;
  final String title;
  const ImageDetailScreen({super.key, required this.imageId, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(imageDetailProvider(imageId));
    final history = ref.watch(imageHistoryProvider(imageId));
    final client = ref.read(dockerClientProvider);
    final messenger = ScaffoldMessenger.of(context);

    Future<void> run(Future<void> Function() action, String ok) async {
      try {
        await action();
        messenger.showSnackBar(SnackBar(content: Text(ok)));
        ref.invalidate(imagesProvider);
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }

    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text('${d.architecture}/${d.os}  ·  ${(d.size / (1024 * 1024)).toStringAsFixed(1)} MB'),
            const SizedBox(height: 4),
            Text('Created: ${d.created}'),
            if (d.exposedPorts.isNotEmpty) Text('Exposed: ${d.exposedPorts.join(', ')}'),
            if (d.env.isNotEmpty) Text('Env: ${d.env.join('\n')}'),
            const Divider(height: 24),
            Wrap(spacing: 8, children: [
              OutlinedButton(
                onPressed: () async {
                  final t = await _tagDialog(context);
                  if (t != null && client != null && context.mounted) {
                    await run(() => client.tagImage(imageId, repo: t.$1, tag: t.$2), 'Tagged');
                  }
                },
                child: const Text('Tag'),
              ),
              ElevatedButton(
                onPressed: () async {
                  final opts = await _removeImageDialog(context);
                  if (opts != null && client != null && context.mounted) {
                    await run(() => client.removeImage(imageId, force: opts.$1, noprune: opts.$2), 'Removed');
                    if (context.mounted) Navigator.of(context).pop();
                  }
                },
                child: const Text('Remove'),
              ),
            ]),
            const Divider(height: 24),
            const Text('History', style: TextStyle(fontWeight: FontWeight.bold)),
            ...history.maybeWhen(
              data: (layers) => layers.map((l) => ListTile(
                    dense: true,
                    title: Text(l.createdBy, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Text('${(l.size / (1024 * 1024)).toStringAsFixed(1)} MB'),
                  )),
              orElse: () => [const ListTile(dense: true, title: Text('Loading history…'))],
            ),
          ],
        ),
      ),
    );
  }
}

Future<(String, String)?> _tagDialog(BuildContext context) async {
  final repo = TextEditingController();
  final tag = TextEditingController(text: 'latest');
  try {
    return await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tag image'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: repo, decoration: const InputDecoration(labelText: 'Repository')),
          TextField(controller: tag, decoration: const InputDecoration(labelText: 'Tag')),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, (repo.text, tag.text)), child: const Text('Tag')),
        ],
      ),
    );
  } finally {
    repo.dispose();
    tag.dispose();
  }
}

Future<(bool, bool)?> _removeImageDialog(BuildContext context) {
  var force = false;
  var noprune = false;
  return showDialog<(bool, bool)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Remove image?'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          SwitchListTile(title: const Text('Force'), value: force, onChanged: (v) => setState(() => force = v)),
          SwitchListTile(title: const Text('No prune'), value: noprune, onChanged: (v) => setState(() => noprune = v)),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, (force, noprune)), child: const Text('Remove')),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/image_detail_screen_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/state/providers.dart app/lib/src/ui/image_detail_screen.dart app/test/ui/image_detail_screen_test.dart
git commit -m "feat(app): ImageDetailScreen (inspect + history + tag/remove)"
```

---

## Task 6: HomeScreen (bottom nav) + ImagesScreen + connect lands on Home

**Files:**
- Modify: `app/lib/src/state/providers.dart`
- Create: `app/lib/src/ui/images_screen.dart`, `app/lib/src/ui/home_screen.dart`
- Modify: `app/lib/src/ui/connection_screen.dart`
- Test: `app/test/ui/home_screen_test.dart`, `app/test/ui/images_screen_test.dart`

**Interfaces:**
- Consumes: `listImages`/`pruneImages` (Task 3), `DockerImage` (Task 2), `PullSheet` (Task 4), `ImageDetailScreen` (Task 5), `ContainersScreen` (existing).
- Produces: `imagesProvider = FutureProvider<List<DockerImage>>`; `class ImagesScreen extends ConsumerWidget`; `class HomeScreen extends ConsumerStatefulWidget`.

- [ ] **Step 1: Add imagesProvider**

In `app/lib/src/state/providers.dart`, add `import '../api/models/docker_image.dart';` and:
```dart
final imagesProvider = FutureProvider<List<DockerImage>>((ref) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.listImages();
});
```

- [ ] **Step 2: Write the failing tests**

Create `app/test/ui/images_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/images_screen.dart';

class _FakeTransport implements Transport {
  final List<String> posts = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async =>
      http.Response('[{"Id":"sha256:abc","RepoTags":["nginx:latest"],"Size":1048576,"Created":0}]', 200);
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(path);
    return http.Response('', 200);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 200);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  testWidgets('lists images and confirms Prune', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ImagesScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('nginx:latest'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.cleaning_services));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}
```

Create `app/test/ui/home_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/home_screen.dart';

class _FakeTransport implements Transport {
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 200);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  testWidgets('switches between Containers and Images tabs', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => _FakeTransport())],
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Containers'), findsWidgets); // containers tab app bar/label
    await tester.tap(find.byIcon(Icons.layers)); // Images nav item
    await tester.pumpAndSettle();
    expect(find.text('Images'), findsWidgets);
  });
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/images_screen_test.dart test/ui/home_screen_test.dart`
Expected: FAIL — `ImagesScreen`/`HomeScreen` undefined.

- [ ] **Step 4: Write ImagesScreen**

Create `app/lib/src/ui/images_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'image_detail_screen.dart';
import 'pull_sheet.dart';

class ImagesScreen extends ConsumerWidget {
  const ImagesScreen({super.key});

  String _name(List<String> tags, String id) =>
      tags.isNotEmpty && tags.first != '<none>:<none>' ? tags.first : '<none> (${id.length > 19 ? id.substring(7, 19) : id})';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final images = ref.watch(imagesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Images'),
        actions: [
          IconButton(
            tooltip: 'Pull',
            icon: const Icon(Icons.download),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PullSheet())),
          ),
          IconButton(
            tooltip: 'Prune',
            icon: const Icon(Icons.cleaning_services),
            onPressed: () => _prune(context, ref),
          ),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(imagesProvider)),
        ],
      ),
      body: images.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => ListView.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final img = list[i];
            final name = _name(img.repoTags, img.id);
            return ListTile(
              leading: const Icon(Icons.inventory_2),
              title: Text(name),
              subtitle: Text('${(img.size / (1024 * 1024)).toStringAsFixed(1)} MB'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ImageDetailScreen(imageId: img.id, title: name))),
            );
          },
        ),
      ),
    );
  }

  Future<void> _prune(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final danglingOnly = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Prune images'),
        content: const Text('Remove dangling images only, or all unused?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('All unused')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Dangling')),
        ],
      ),
    );
    if (danglingOnly == null) return;
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    try {
      await client.pruneImages(danglingOnly: danglingOnly);
      ref.invalidate(imagesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Pruned')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}
```

- [ ] **Step 5: Write HomeScreen**

Create `app/lib/src/ui/home_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'containers_screen.dart';
import 'images_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _index,
        children: const [ContainersScreen(), ImagesScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inventory), label: 'Containers'),
          NavigationDestination(icon: Icon(Icons.layers), label: 'Images'),
        ],
      ),
    );
  }
}
```

- [ ] **Step 6: Land on HomeScreen after connecting**

In `app/lib/src/ui/connection_screen.dart`, change the import `import 'containers_screen.dart';` to `import 'home_screen.dart';`, and in `_connect`, change the navigation target from `const ContainersScreen()` to `const HomeScreen()`:
```dart
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HomeScreen()),
    );
```

- [ ] **Step 7: Run analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; **all** app tests pass. (The existing `widget_test.dart` asserts the connection screen boots — unaffected. If any test asserted `ContainersScreen` is the post-connect screen, update it to `HomeScreen`.)

- [ ] **Step 8: Commit**

```bash
git add app/lib/src/state/providers.dart app/lib/src/ui/images_screen.dart app/lib/src/ui/home_screen.dart app/lib/src/ui/connection_screen.dart app/test/ui/home_screen_test.dart app/test/ui/images_screen_test.dart
git commit -m "feat(app): HomeScreen bottom nav + ImagesScreen; connect lands on Home"
```

---

## Self-Review

**1. Spec coverage:**
- `Transport.postStream` → Task 1. ✓
- Image models (DockerImage/ImageDetail/ImageHistoryLayer/PullEvent) → Task 2. ✓
- Client methods (list/inspect/history/pull-stream/tag/remove/prune) → Task 3. ✓
- `PullSheet` live progress + ref parsing + error → Task 4. ✓
- `ImageDetailScreen` (inspect + history + tag/remove) + providers → Task 5. ✓
- `HomeScreen` bottom nav + `ImagesScreen` (list/pull/prune/refresh/tap) + connect-lands-on-Home + imagesProvider → Task 6. ✓
- Error handling (in-band pull error, snackbars, cancel on leave) → Tasks 3/4/5/6. ✓
- Out of scope (build/save/load/search/push, networks/volumes/system) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code step is complete. The pull-line parser explicitly skips undecodable fragments (concrete behavior, not a vague guard).

**3. Type consistency:** `postStream(path,{query,body})` (Task 1) consumed by `pullImage` (Task 3) and the fakes. Models (Task 2) used by Task 3/5/6. `pullImage(image,{tag})→Stream<PullEvent>` (Task 3) used by `PullSheet` (Task 4). `tagImage(id,{repo,tag})`/`removeImage(id,{force,noprune})` (Task 3) used by `ImageDetailScreen` (Task 5). `imageDetailProvider`/`imageHistoryProvider` (Task 5) + `imagesProvider` (Task 6) watched by their screens. `PullSheet()`/`ImageDetailScreen(imageId,title)`/`ImagesScreen()`/`HomeScreen()` constructors match their call sites. `parseImageRef` returns `(String image, String tag)`. ✓
