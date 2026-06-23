# Phase 1C-1 — Container Detail & Lifecycle Actions — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A container detail screen (the per-container hub) plus lifecycle write actions — start/stop/restart/pause/unpause/kill/rename/remove — over the existing agent transport.

**Architecture:** App-only. Add `Transport.delete`, a rich `ContainerDetail` model, `DockerApiClient` inspect-detail + action methods, a `containerDetailProvider`, and a `ContainerDetailScreen` reached by tapping a container row (Logs/Exec become buttons inside it).

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `http` (all existing).

## Global Constraints

- **App-only slice:** no agent changes. All calls go through the single `DockerApiClient` over `Transport` (agent transport in practice).
- **Status handling:** action success = HTTP `204`; `304` (already started/stopped) is a successful no-op for start/stop ONLY; any other non-success → `DockerApiException(statusCode, body)`.
- **Actions in scope:** start, stop, restart, pause, unpause, kill, rename, remove (force + remove-volumes). NOT in scope: container create/run, update/resources, top/stats/diff/cp/export.
- **Navigation:** container row tap → `ContainerDetailScreen`; the row's trailing exec icon is REMOVED (Logs/Exec are buttons in detail). Model: new `ContainerDetail`; the existing `ContainerInspect` is unchanged (still used by logs for `tty`).
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits, commit messages with NO `Co-Authored-By` trailer. Repo local/private on a feature branch.

---

## File Structure

```
app/lib/src/transport/transport.dart           # + delete
app/lib/src/transport/agent_transport.dart      # + delete
app/lib/src/api/models/container_detail.dart     # ContainerDetail + ContainerStateInfo + PortMapping + MountInfo
app/lib/src/api/docker_api_client.dart           # + inspectContainerDetail + 8 action methods
app/lib/src/state/providers.dart                 # + containerDetailProvider
app/lib/src/ui/container_detail_screen.dart      # ContainerDetailScreen
app/lib/src/ui/containers_screen.dart            # tap -> detail; remove exec icon

app/test/transport/agent_transport_delete_test.dart
app/test/api/models/container_detail_test.dart
app/test/api/docker_api_client_actions_test.dart
app/test/ui/container_detail_screen_test.dart
# + delete() stub added to existing Transport fakes (Task 1)
```

---

## Task 1: Transport.delete

**Files:**
- Modify: `app/lib/src/transport/transport.dart`, `app/lib/src/transport/agent_transport.dart`
- Modify (stubs): `app/test/api/docker_api_client_test.dart`, `app/test/api/docker_api_client_logs_test.dart`, `app/test/api/docker_api_client_exec_test.dart`, `app/test/state/logs_notifier_test.dart`, `app/test/state/exec_session_controller_test.dart`, `app/test/ui/logs_screen_test.dart`, `app/test/ui/exec_screen_test.dart`
- Test: `app/test/transport/agent_transport_delete_test.dart`

**Interfaces:**
- Produces: `Transport.delete(String path, {Map<String,String>? query}) → Future<http.Response>`; `AgentTransport` implements it (HTTP DELETE + bearer header).

- [ ] **Step 1: Write the failing test**

Create `app/test/transport/agent_transport_delete_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';

void main() {
  test('delete sends DELETE with bearer + query', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response('', 204);
    });
    final t = AgentTransport(baseUri: Uri.parse('http://h:8080'), token: 'secret', client: mock);

    final resp = await t.delete('/containers/c', query: {'force': 'true', 'v': 'true'});

    expect(resp.statusCode, 204);
    expect(captured.method, 'DELETE');
    expect(captured.headers['Authorization'], 'Bearer secret');
    expect(captured.url.path, '/containers/c');
    expect(captured.url.queryParameters, {'force': 'true', 'v': 'true'});
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/agent_transport_delete_test.dart`
Expected: FAIL — `delete` not defined on `AgentTransport`.

- [ ] **Step 3: Add to the interface**

In `app/lib/src/transport/transport.dart`, add this method to the `abstract class Transport` (after `execAttach`):
```dart
  /// DELETE with optional query params (e.g. container remove).
  Future<http.Response> delete(String path, {Map<String, String>? query});
```

- [ ] **Step 4: Implement in AgentTransport**

In `app/lib/src/transport/agent_transport.dart`, add this method to the class (after `post`):
```dart
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    return _client.delete(uri, headers: {'Authorization': 'Bearer $token'});
  }
```

- [ ] **Step 5: Add the `delete` stub to every existing Transport fake**

Add this override to each fake class listed in **Files** (they don't use delete). For files that don't already `import 'package:http/http.dart' as http;`, that import already exists in all of them.
```dart
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      throw UnimplementedError();
```
Fakes to update: `_FakeTransport` in `docker_api_client_test.dart`, `docker_api_client_logs_test.dart`, `docker_api_client_exec_test.dart`, `logs_screen_test.dart`, `exec_screen_test.dart`; `_FakeTransport` AND `_ControllerTransport` in `logs_notifier_test.dart`; `_ExecFakeTransport` in `exec_session_controller_test.dart`.

- [ ] **Step 6: Run the tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; all tests pass (new delete test + every prior suite).

- [ ] **Step 7: Commit**

```bash
git add app/lib/src/transport app/test
git commit -m "feat(app): Transport.delete + AgentTransport implementation"
```

---

## Task 2: ContainerDetail model

**Files:**
- Create: `app/lib/src/api/models/container_detail.dart`
- Test: `app/test/api/models/container_detail_test.dart`

**Interfaces:**
- Produces:
  - `class ContainerStateInfo { final String status; final bool running; final bool paused; final int? exitCode; final String? startedAt; }`
  - `class PortMapping { final String? ip; final int? privatePort; final int? publicPort; final String type; }`
  - `class MountInfo { final String source; final String destination; final String mode; final bool rw; }`
  - `class ContainerDetail { final String id, name, image, command, created; final ContainerStateInfo state; final List<PortMapping> ports; final List<MountInfo> mounts; final List<String> env; final String restartPolicy; final List<String> networks; factory ContainerDetail.fromJson(Map<String,dynamic>); }`

- [ ] **Step 1: Write the failing test**

Create `app/test/api/models/container_detail_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container_detail.dart';

void main() {
  test('parses a full /containers/{id}/json', () {
    final c = ContainerDetail.fromJson({
      'Id': 'abc',
      'Name': '/web',
      'Created': '2026-01-02T03:04:05Z',
      'Config': {'Image': 'nginx', 'Cmd': ['nginx', '-g', 'daemon off;'], 'Env': ['A=1', 'B=2']},
      'State': {'Status': 'running', 'Running': true, 'Paused': false, 'ExitCode': 0, 'StartedAt': '2026-01-02T03:04:06Z'},
      'HostConfig': {'RestartPolicy': {'Name': 'unless-stopped'}},
      'Mounts': [
        {'Source': '/data', 'Destination': '/var/lib', 'Mode': 'rw', 'RW': true},
      ],
      'NetworkSettings': {
        'Networks': {'bridge': {}, 'frontend': {}},
        'Ports': {
          '80/tcp': [{'HostIp': '0.0.0.0', 'HostPort': '8080'}],
          '443/tcp': null,
        },
      },
    });

    expect(c.id, 'abc');
    expect(c.name, 'web');
    expect(c.image, 'nginx');
    expect(c.command, 'nginx -g daemon off;');
    expect(c.created, '2026-01-02T03:04:05Z');
    expect(c.state.status, 'running');
    expect(c.state.running, isTrue);
    expect(c.state.exitCode, 0);
    expect(c.env, ['A=1', 'B=2']);
    expect(c.restartPolicy, 'unless-stopped');
    expect(c.networks, containsAll(['bridge', 'frontend']));
    expect(c.mounts.single.source, '/data');
    expect(c.mounts.single.rw, isTrue);
    // 80/tcp bound to 8080; 443/tcp unbound.
    expect(c.ports.any((p) => p.privatePort == 80 && p.publicPort == 8080 && p.type == 'tcp'), isTrue);
    expect(c.ports.any((p) => p.privatePort == 443 && p.publicPort == null), isTrue);
  });

  test('tolerates missing nested objects', () {
    final c = ContainerDetail.fromJson({'Id': 'x', 'Name': 'y'});
    expect(c.image, '');
    expect(c.command, '');
    expect(c.state.status, '');
    expect(c.ports, isEmpty);
    expect(c.mounts, isEmpty);
    expect(c.env, isEmpty);
    expect(c.networks, isEmpty);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/container_detail_test.dart`
Expected: FAIL — `ContainerDetail` undefined.

- [ ] **Step 3: Write the implementation**

Create `app/lib/src/api/models/container_detail.dart`:
```dart
class ContainerStateInfo {
  final String status;
  final bool running;
  final bool paused;
  final int? exitCode;
  final String? startedAt;
  const ContainerStateInfo({
    required this.status,
    required this.running,
    required this.paused,
    this.exitCode,
    this.startedAt,
  });

  factory ContainerStateInfo.fromJson(Map<String, dynamic> json) => ContainerStateInfo(
        status: json['Status'] as String? ?? '',
        running: json['Running'] as bool? ?? false,
        paused: json['Paused'] as bool? ?? false,
        exitCode: json['ExitCode'] as int?,
        startedAt: json['StartedAt'] as String?,
      );
}

class PortMapping {
  final String? ip;
  final int? privatePort;
  final int? publicPort;
  final String type;
  const PortMapping({this.ip, this.privatePort, this.publicPort, required this.type});
}

class MountInfo {
  final String source;
  final String destination;
  final String mode;
  final bool rw;
  const MountInfo({required this.source, required this.destination, required this.mode, required this.rw});

  factory MountInfo.fromJson(Map<String, dynamic> json) => MountInfo(
        source: json['Source'] as String? ?? '',
        destination: json['Destination'] as String? ?? '',
        mode: json['Mode'] as String? ?? '',
        rw: json['RW'] as bool? ?? false,
      );
}

/// Rich view of `GET /containers/{id}/json` for the detail screen.
class ContainerDetail {
  final String id;
  final String name;
  final String image;
  final String command;
  final String created;
  final ContainerStateInfo state;
  final List<PortMapping> ports;
  final List<MountInfo> mounts;
  final List<String> env;
  final String restartPolicy;
  final List<String> networks;

  const ContainerDetail({
    required this.id,
    required this.name,
    required this.image,
    required this.command,
    required this.created,
    required this.state,
    required this.ports,
    required this.mounts,
    required this.env,
    required this.restartPolicy,
    required this.networks,
  });

  factory ContainerDetail.fromJson(Map<String, dynamic> json) {
    final config = (json['Config'] as Map<String, dynamic>?) ?? const {};
    final stateObj = (json['State'] as Map<String, dynamic>?) ?? const {};
    final hostConfig = (json['HostConfig'] as Map<String, dynamic>?) ?? const {};
    final netSettings = (json['NetworkSettings'] as Map<String, dynamic>?) ?? const {};
    final rawName = json['Name'] as String? ?? '';
    final cmd = (config['Cmd'] as List?)?.cast<String>() ?? const <String>[];
    return ContainerDetail(
      id: json['Id'] as String? ?? '',
      name: rawName.startsWith('/') ? rawName.substring(1) : rawName,
      image: config['Image'] as String? ?? '',
      command: cmd.join(' '),
      created: json['Created'] as String? ?? '',
      state: ContainerStateInfo.fromJson(stateObj),
      ports: _parsePorts(netSettings['Ports'] as Map<String, dynamic>?),
      mounts: ((json['Mounts'] as List?) ?? const [])
          .map((m) => MountInfo.fromJson(m as Map<String, dynamic>))
          .toList(),
      env: (config['Env'] as List?)?.cast<String>() ?? const [],
      restartPolicy: (hostConfig['RestartPolicy'] as Map<String, dynamic>?)?['Name'] as String? ?? '',
      networks: (netSettings['Networks'] as Map<String, dynamic>?)?.keys.toList() ?? const [],
    );
  }

  static List<PortMapping> _parsePorts(Map<String, dynamic>? ports) {
    if (ports == null) return const [];
    final result = <PortMapping>[];
    ports.forEach((key, value) {
      final parts = key.split('/');
      final priv = int.tryParse(parts.first);
      final type = parts.length > 1 ? parts[1] : 'tcp';
      final bindings = value as List?;
      if (bindings == null || bindings.isEmpty) {
        result.add(PortMapping(privatePort: priv, type: type));
      } else {
        for (final b in bindings) {
          final bm = b as Map<String, dynamic>;
          result.add(PortMapping(
            ip: bm['HostIp'] as String?,
            privatePort: priv,
            publicPort: int.tryParse(bm['HostPort'] as String? ?? ''),
            type: type,
          ));
        }
      }
    });
    return result;
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/container_detail_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/models/container_detail.dart app/test/api/models/container_detail_test.dart
git commit -m "feat(app): ContainerDetail model with ports/mounts/state parsing"
```

---

## Task 3: DockerApiClient — inspect-detail + lifecycle actions

**Files:**
- Modify: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/docker_api_client_actions_test.dart`

**Interfaces:**
- Consumes: `Transport` (Task 1), `ContainerDetail` (Task 2).
- Produces, on `DockerApiClient`: `inspectContainerDetail(id)`, `startContainer(id)`, `stopContainer(id)`, `restartContainer(id)`, `pauseContainer(id)`, `unpauseContainer(id)`, `killContainer(id)`, `renameContainer(id, newName)`, `removeContainer(id, {force, removeVolumes})`.

- [ ] **Step 1: Write the failing test**

Create `app/test/api/docker_api_client_actions_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _Rec {
  final String verb; // 'post' | 'delete' | 'get'
  final String path;
  final Map<String, String>? query;
  _Rec(this.verb, this.path, this.query);
}

class _FakeTransport implements Transport {
  final List<_Rec> calls = [];
  int postStatus = 204;
  int deleteStatus = 204;
  http.Response getResponse = http.Response('{"Id":"a","Name":"/web"}', 200);

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
}

void main() {
  test('inspectContainerDetail parses the rich model', () async {
    final t = _FakeTransport()..getResponse = http.Response('{"Id":"a","Name":"/web","Config":{"Image":"nginx"}}', 200);
    final c = await DockerApiClient(t).inspectContainerDetail('a');
    expect(c.image, 'nginx');
    expect(t.calls.single.path, '/containers/a/json');
  });

  test('start succeeds on 204 and on 304', () async {
    final t = _FakeTransport()..postStatus = 204;
    await DockerApiClient(t).startContainer('a');
    expect(t.calls.last.path, '/containers/a/start');

    t.postStatus = 304;
    await DockerApiClient(t).startContainer('a'); // must NOT throw
  });

  test('restart/pause/unpause/kill post to the right paths', () async {
    final t = _FakeTransport();
    final c = DockerApiClient(t);
    await c.restartContainer('a');
    await c.pauseContainer('a');
    await c.unpauseContainer('a');
    await c.killContainer('a');
    expect(t.calls.map((r) => r.path).toList(),
        ['/containers/a/restart', '/containers/a/pause', '/containers/a/unpause', '/containers/a/kill']);
  });

  test('rename posts the name query', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).renameContainer('a', 'newname');
    expect(t.calls.last.path, '/containers/a/rename');
    expect(t.calls.last.query, {'name': 'newname'});
  });

  test('remove deletes with force + v query', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).removeContainer('a', force: true, removeVolumes: true);
    expect(t.calls.last.verb, 'delete');
    expect(t.calls.last.path, '/containers/a');
    expect(t.calls.last.query, {'force': 'true', 'v': 'true'});
  });

  test('a 409 on remove throws DockerApiException', () async {
    final t = _FakeTransport()..deleteStatus = 409;
    expect(() => DockerApiClient(t).removeContainer('a'), throwsA(isA<DockerApiException>()));
  });

  test('a 500 on start throws DockerApiException', () async {
    final t = _FakeTransport()..postStatus = 500;
    expect(() => DockerApiClient(t).startContainer('a'), throwsA(isA<DockerApiException>()));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/docker_api_client_actions_test.dart`
Expected: FAIL — action methods undefined.

- [ ] **Step 3: Add the methods**

In `app/lib/src/api/docker_api_client.dart`, add `import 'models/container_detail.dart';`, then append inside `DockerApiClient`:
```dart
  void _ensure(http.Response resp, {Set<int> ok = const {204}}) {
    if (!ok.contains(resp.statusCode)) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
  }

  Future<ContainerDetail> inspectContainerDetail(String id) async {
    final resp = await transport.get('/containers/$id/json');
    if (resp.statusCode != 200) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    return ContainerDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> startContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/start'), ok: const {204, 304});

  Future<void> stopContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/stop'), ok: const {204, 304});

  Future<void> restartContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/restart'));

  Future<void> pauseContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/pause'));

  Future<void> unpauseContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/unpause'));

  Future<void> killContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/kill'));

  Future<void> renameContainer(String id, String newName) async =>
      _ensure(await transport.post('/containers/$id/rename', query: {'name': newName}));

  Future<void> removeContainer(String id, {bool force = false, bool removeVolumes = false}) async =>
      _ensure(await transport.delete('/containers/$id', query: {'force': '$force', 'v': '$removeVolumes'}));
```
(`http` is already imported in this file as `package:http/http.dart`? It uses `transport` which returns `http.Response`; the file already imports `dart:convert`. Add `import 'package:http/http.dart' as http;` if `_ensure`'s `http.Response` param is otherwise unresolved — check the existing imports and add it if missing.)

- [ ] **Step 4: Run the tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/ && flutter analyze`
Expected: PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/docker_api_client.dart app/test/api/docker_api_client_actions_test.dart
git commit -m "feat(app): DockerApiClient container detail + lifecycle actions"
```

---

## Task 4: containerDetailProvider + ContainerDetailScreen + navigation

**Files:**
- Modify: `app/lib/src/state/providers.dart`
- Create: `app/lib/src/ui/container_detail_screen.dart`
- Modify: `app/lib/src/ui/containers_screen.dart`
- Test: `app/test/ui/container_detail_screen_test.dart`

**Interfaces:**
- Consumes: `DockerApiClient` actions + `inspectContainerDetail` (Task 3), `ContainerDetail`/`ContainerStateInfo` (Task 2), `dockerClientProvider`/`containersProvider` (existing), `LogsScreen`/`ExecScreen` (existing).
- Produces: `final containerDetailProvider = FutureProvider.family<ContainerDetail, String>(...)`; `class ContainerDetailScreen extends ConsumerWidget { const ContainerDetailScreen({required this.containerId, required this.containerName}); }`.

- [ ] **Step 1: Add the provider**

In `app/lib/src/state/providers.dart`, add `import '../api/models/container_detail.dart';` and:
```dart
/// Rich inspect for the container detail screen.
final containerDetailProvider = FutureProvider.family<ContainerDetail, String>((ref, id) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.inspectContainerDetail(id);
});
```

- [ ] **Step 2: Write the failing widget test**

Create `app/test/ui/container_detail_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/container_detail_screen.dart';

class _FakeTransport implements Transport {
  final String status; // container State.Status
  final bool running;
  final List<String> posts = [];
  final List<String> deletes = [];
  _FakeTransport({this.status = 'running', this.running = true});

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response(
        '{"Id":"a","Name":"/web","Config":{"Image":"nginx"},"State":{"Status":"$status","Running":$running,"Paused":false}}',
        200,
      );
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(path);
    return http.Response('', 204);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    deletes.add(path);
    return http.Response('', 204);
  }
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
}

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ContainerDetailScreen(containerId: 'a', containerName: 'web')),
    );

void main() {
  testWidgets('renders detail and a stopped container offers Start', (tester) async {
    final t = _FakeTransport(status: 'exited', running: false);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget); // app bar title
    expect(find.textContaining('nginx'), findsWidgets); // image shown
    expect(find.widgetWithText(ElevatedButton, 'Start'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Start'));
    await tester.pumpAndSettle();
    expect(t.posts, contains('/containers/a/start'));
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('Remove opens a confirmation dialog', (tester) async {
    final t = _FakeTransport(status: 'running', running: true);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Force'), findsOneWidget);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/container_detail_screen_test.dart`
Expected: FAIL — `ContainerDetailScreen` undefined.

- [ ] **Step 4: Write the ContainerDetailScreen**

Create `app/lib/src/ui/container_detail_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_detail.dart';
import '../state/providers.dart';
import 'logs_screen.dart';
import 'exec_screen.dart';

class ContainerDetailScreen extends ConsumerWidget {
  final String containerId;
  final String containerName;
  const ContainerDetailScreen({super.key, required this.containerId, required this.containerName});

  Future<void> _run(BuildContext context, WidgetRef ref, Future<void> Function() action, String okMsg) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await action();
      ref.invalidate(containerDetailProvider(containerId));
      ref.invalidate(containersProvider);
      messenger.showSnackBar(SnackBar(content: Text(okMsg)));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(containerDetailProvider(containerId));
    return Scaffold(
      appBar: AppBar(
        title: Text(containerName),
        actions: [
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(containerDetailProvider(containerId))),
        ],
      ),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (c) => _Body(detail: c, containerId: containerId, containerName: containerName, onRun: _run),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  final ContainerDetail detail;
  final String containerId;
  final String containerName;
  final Future<void> Function(BuildContext, WidgetRef, Future<void> Function(), String) onRun;
  const _Body({required this.detail, required this.containerId, required this.containerName, required this.onRun});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final client = ref.read(dockerClientProvider)!;
    final s = detail.state;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _StateBadge(state: s),
        const SizedBox(height: 12),
        _kv('Image', detail.image),
        if (detail.command.isNotEmpty) _kv('Command', detail.command),
        if (detail.created.isNotEmpty) _kv('Created', detail.created),
        if (detail.restartPolicy.isNotEmpty) _kv('Restart policy', detail.restartPolicy),
        if (detail.networks.isNotEmpty) _kv('Networks', detail.networks.join(', ')),
        if (detail.ports.isNotEmpty)
          _kv('Ports', detail.ports.map((p) => '${p.publicPort != null ? '${p.publicPort}->' : ''}${p.privatePort}/${p.type}').join(', ')),
        if (detail.mounts.isNotEmpty)
          _kv('Mounts', detail.mounts.map((m) => '${m.source}:${m.destination}${m.rw ? '' : ' (ro)'}').join('\n')),
        if (detail.env.isNotEmpty) _kv('Env', detail.env.join('\n')),
        const Divider(height: 32),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!s.running)
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.startContainer(containerId), 'Started'), child: const Text('Start')),
            if (s.running && !s.paused) ...[
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.stopContainer(containerId), 'Stopped'), child: const Text('Stop')),
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.restartContainer(containerId), 'Restarted'), child: const Text('Restart')),
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.pauseContainer(containerId), 'Paused'), child: const Text('Pause')),
            ],
            if (s.paused)
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.unpauseContainer(containerId), 'Unpaused'), child: const Text('Unpause')),
            if (s.running)
              ElevatedButton(
                onPressed: () async {
                  if (await _confirm(context, 'Kill container?', 'Sends SIGKILL immediately.')) {
                    await onRun(context, ref, () => client.killContainer(containerId), 'Killed');
                  }
                },
                child: const Text('Kill'),
              ),
            OutlinedButton(
              onPressed: () async {
                final name = await _renameDialog(context, containerName);
                if (name != null && name.isNotEmpty) {
                  await onRun(context, ref, () => client.renameContainer(containerId, name), 'Renamed');
                }
              },
              child: const Text('Rename'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.errorContainer),
              onPressed: () async {
                final opts = await _removeDialog(context);
                if (opts != null) {
                  await onRun(context, ref,
                      () => client.removeContainer(containerId, force: opts.$1, removeVolumes: opts.$2), 'Removed');
                }
              },
              child: const Text('Remove'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.article),
              label: const Text('Logs'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => LogsScreen(containerId: containerId, containerName: containerName))),
            )),
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.terminal),
              label: const Text('Exec'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ExecScreen(containerId: containerId, containerName: containerName))),
            )),
          ],
        ),
      ],
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 110, child: Text(k, style: const TextStyle(fontWeight: FontWeight.bold))),
            Expanded(child: Text(v)),
          ],
        ),
      );
}

class _StateBadge extends StatelessWidget {
  final ContainerStateInfo state;
  const _StateBadge({required this.state});
  @override
  Widget build(BuildContext context) {
    final running = state.running;
    final color = state.paused ? Colors.orange : (running ? Colors.green : Colors.grey);
    final label = state.paused ? 'paused' : state.status;
    return Row(children: [
      Icon(Icons.circle, size: 12, color: color),
      const SizedBox(width: 8),
      Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
      if (!running && state.exitCode != null) Text('  (exit ${state.exitCode})'),
    ]);
  }
}

Future<bool> _confirm(BuildContext context, String title, String message) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Confirm')),
      ],
    ),
  );
  return ok ?? false;
}

Future<String?> _renameDialog(BuildContext context, String current) {
  final ctl = TextEditingController(text: current);
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Rename container'),
      content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(labelText: 'New name')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Rename')),
      ],
    ),
  );
}

/// Returns (force, removeVolumes) or null if cancelled.
Future<(bool, bool)?> _removeDialog(BuildContext context) {
  var force = false;
  var removeVolumes = false;
  return showDialog<(bool, bool)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Remove container?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SwitchListTile(title: const Text('Force'), value: force, onChanged: (v) => setState(() => force = v)),
            SwitchListTile(title: const Text('Remove volumes'), value: removeVolumes, onChanged: (v) => setState(() => removeVolumes = v)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, (force, removeVolumes)), child: const Text('Remove')),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 5: Run the widget test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/container_detail_screen_test.dart`
Expected: PASS (both tests).

- [ ] **Step 6: Refactor ContainersScreen navigation**

In `app/lib/src/ui/containers_screen.dart`:
- Replace the import line `import 'exec_screen.dart';` with `import 'container_detail_screen.dart';` (remove the `logs_screen.dart` import too if present — the row no longer opens logs directly).
- Remove the `trailing: IconButton(... Exec ...)` block from the `ListTile`.
- Change the `ListTile`'s `onTap` to open the detail screen:
```dart
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ContainerDetailScreen(containerId: c.id, containerName: name),
                ),
              ),
```
The final `ListTile` should have `leading`, `title`, `subtitle`, and this `onTap` — and NO `trailing`.

- [ ] **Step 7: Run analyzer + the full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean (no unused imports); **all** app tests pass (note: `containers_screen` has no dedicated test that asserts the exec icon, so removing it won't break a test; if one exists, update it).

- [ ] **Step 8: Commit**

```bash
git add app/lib/src/state/providers.dart app/lib/src/ui/container_detail_screen.dart app/lib/src/ui/containers_screen.dart app/test/ui/container_detail_screen_test.dart
git commit -m "feat(app): container detail screen with lifecycle actions; row tap -> detail hub"
```

---

## Self-Review

**1. Spec coverage:**
- `Transport.delete` → Task 1. ✓
- `ContainerDetail` model (state/ports/mounts/env/networks/restart) → Task 2. ✓
- `inspectContainerDetail` + 8 actions with 204/304 handling → Task 3. ✓
- `containerDetailProvider` → Task 4. ✓
- `ContainerDetailScreen` (overview + state-aware actions + confirm/rename/remove dialogs + Logs/Exec buttons) → Task 4. ✓
- Navigation refactor (row tap → detail; exec icon removed) → Task 4 Step 6. ✓
- Error handling (snackbars, 409 surfaced via exception text, refresh) → Task 4 `_run`. ✓
- Out of scope (create/update/top/stats/cp) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code step is complete. The one conditional note (add `import http` if unresolved in Task 3) is a concrete check, not a vague instruction.

**3. Type consistency:** `Transport.delete(path,{query})` (Task 1) used by `removeContainer` (Task 3). `ContainerDetail`/`ContainerStateInfo`/`PortMapping`/`MountInfo` (Task 2) used by Task 3 (`inspectContainerDetail`) and Task 4 (screen). The 8 action method names + `removeContainer(id,{force,removeVolumes})` (Task 3) called exactly in Task 4's buttons. `containerDetailProvider` family-by-String (Task 4 Step 1) watched in the screen (Task 4 Step 4). `_run`'s signature matches its call sites. ✓
