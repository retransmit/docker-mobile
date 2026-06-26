# Phase 2A — Container Create / Run — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create and run containers from the app — a rich create form (`POST /containers/create` + optional start) with pull-if-missing.

**Architecture:** A pure `ContainerCreateConfig` builds the Docker create JSON; `DockerApiClient.createContainer` posts it; a `CreateContainerScreen` form (reusing `KeyValueEditor` + a new `PortMappingEditor`, the `networksProvider`, and the existing pull stream) orchestrates create → optional start → pop, and on a 404 offers to pull then retries. Reached from a Containers-tab FAB and an Image-detail Run button.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `http` (all existing).

## Global Constraints

- **App-only slice:** no agent changes; NO new `Transport` methods (use existing `post`/`postStream`). All calls go through `DockerApiClient`.
- **Status codes:** `createContainer` = `201` → parse `Id`; non-201 → `DockerApiException`. Reuse `startContainer` (204/304) and `pullImage`.
- **Rich config:** image (required), name, command, env, ports, volume binds, restart policy, labels, single network, memory (MB), CPUs; `toJson` omits empty sections and omits `HostConfig` entirely if empty.
- **Pull-if-missing:** a create `DockerApiException` with `statusCode == 404` OR body containing `No such image` → confirm dialog → pull the image (live progress) → retry create once.
- **Entry points:** Containers-tab **+** FAB (image typed); `ImageDetailScreen` **Run** (image pre-filled from `title`).
- **Reuse:** `KeyValueEditor` (env/labels/volume-binds), `parseImageRef` (from `pull_sheet.dart`), `pullImage`, `networksProvider`.
- **Async/controller discipline:** capture messenger/navigator BEFORE awaits; mounted guards; dispose all controllers; `StatefulWidget` editors.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/api/models/container_create_config.dart   # ContainerCreateConfig + PortMapping
app/lib/src/api/docker_api_client.dart                # + createContainer
app/lib/src/ui/widgets/port_mapping_editor.dart       # PortMappingEditor
app/lib/src/ui/create_container_screen.dart           # CreateContainerScreen (+ _PullProgressDialog)
app/lib/src/ui/containers_screen.dart                 # + create FAB
app/lib/src/ui/image_detail_screen.dart               # + Run button
app/test/...                                            # mirrors the above
```

---

## Task 1: ContainerCreateConfig + createContainer

**Files:**
- Create: `app/lib/src/api/models/container_create_config.dart`
- Modify: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/models/container_create_config_test.dart`, `app/test/api/docker_api_client_create_test.dart`

**Interfaces:**
- Produces:
  - `class PortMapping { final String containerPort, protocol, hostPort; const PortMapping({required ...}); }`
  - `class ContainerCreateConfig { final String image; final List<String> cmd; final Map<String,String> env; final List<PortMapping> ports; final Map<String,String> binds; final String? restartPolicy; final Map<String,String> labels; final String? network; final int? memoryBytes; final double? cpus; const ContainerCreateConfig({required image, cmd=const[], env=const{}, ports=const[], binds=const{}, restartPolicy, labels=const{}, network, memoryBytes, cpus}); static List<String> parseCommand(String); Map<String,dynamic> toJson(); }`
  - `DockerApiClient.createContainer(ContainerCreateConfig config, {String? name}) -> Future<String>`

- [ ] **Step 1: Write the failing model test**

Create `app/test/api/models/container_create_config_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container_create_config.dart';

void main() {
  test('image-only config has no HostConfig and no extras', () {
    final json = const ContainerCreateConfig(image: 'nginx').toJson();
    expect(json, {'Image': 'nginx'});
  });

  test('parseCommand splits on whitespace; empty -> []', () {
    expect(ContainerCreateConfig.parseCommand('nginx -g daemon off'), ['nginx', '-g', 'daemon', 'off']);
    expect(ContainerCreateConfig.parseCommand('   '), <String>[]);
  });

  test('rich config builds the expected Docker shapes', () {
    final json = const ContainerCreateConfig(
      image: 'nginx:latest',
      cmd: ['echo', 'hi'],
      env: {'K': 'V'},
      ports: [PortMapping(containerPort: '80', protocol: 'tcp', hostPort: '8080')],
      binds: {'/data': '/var/www'},
      restartPolicy: 'unless-stopped',
      labels: {'app': 'web'},
      network: 'frontend',
      memoryBytes: 536870912,
      cpus: 1.5,
    ).toJson();

    expect(json['Image'], 'nginx:latest');
    expect(json['Cmd'], ['echo', 'hi']);
    expect(json['Env'], ['K=V']);
    expect(json['Labels'], {'app': 'web'});
    expect(json['ExposedPorts'], {'80/tcp': {}});
    final hc = json['HostConfig'] as Map<String, dynamic>;
    expect(hc['PortBindings'], {'80/tcp': [{'HostPort': '8080'}]});
    expect(hc['Binds'], ['/data:/var/www']);
    expect(hc['RestartPolicy'], {'Name': 'unless-stopped'});
    expect(hc['NetworkMode'], 'frontend');
    expect(hc['Memory'], 536870912);
    expect(hc['NanoCpus'], 1500000000);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/container_create_config_test.dart`
Expected: FAIL — types undefined.

- [ ] **Step 3: Write the model**

Create `app/lib/src/api/models/container_create_config.dart`:
```dart
class PortMapping {
  final String containerPort;
  final String protocol; // 'tcp' | 'udp'
  final String hostPort;
  const PortMapping({required this.containerPort, required this.protocol, required this.hostPort});
}

/// Builds the JSON body for POST /containers/create. Empty sections are omitted
/// (and HostConfig is omitted entirely when it would be empty).
class ContainerCreateConfig {
  final String image;
  final List<String> cmd;
  final Map<String, String> env;
  final List<PortMapping> ports;
  final Map<String, String> binds; // host -> container
  final String? restartPolicy;
  final Map<String, String> labels;
  final String? network;
  final int? memoryBytes;
  final double? cpus;

  const ContainerCreateConfig({
    required this.image,
    this.cmd = const [],
    this.env = const {},
    this.ports = const [],
    this.binds = const {},
    this.restartPolicy,
    this.labels = const {},
    this.network,
    this.memoryBytes,
    this.cpus,
  });

  /// Whitespace-split (quoted args are out of scope; documented in the form).
  static List<String> parseCommand(String s) =>
      s.trim().isEmpty ? const [] : s.trim().split(RegExp(r'\s+'));

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'Image': image};
    if (cmd.isNotEmpty) json['Cmd'] = cmd;
    if (env.isNotEmpty) json['Env'] = [for (final e in env.entries) '${e.key}=${e.value}'];
    if (labels.isNotEmpty) json['Labels'] = labels;
    if (ports.isNotEmpty) {
      json['ExposedPorts'] = {for (final p in ports) '${p.containerPort}/${p.protocol}': <String, dynamic>{}};
    }

    final hostConfig = <String, dynamic>{};
    if (ports.isNotEmpty) {
      hostConfig['PortBindings'] = {
        for (final p in ports)
          '${p.containerPort}/${p.protocol}': [
            {'HostPort': p.hostPort}
          ]
      };
    }
    if (binds.isNotEmpty) hostConfig['Binds'] = [for (final b in binds.entries) '${b.key}:${b.value}'];
    if (restartPolicy != null && restartPolicy!.isNotEmpty) hostConfig['RestartPolicy'] = {'Name': restartPolicy};
    if (network != null && network!.isNotEmpty) hostConfig['NetworkMode'] = network;
    if (memoryBytes != null) hostConfig['Memory'] = memoryBytes;
    if (cpus != null) hostConfig['NanoCpus'] = (cpus! * 1e9).round();
    if (hostConfig.isNotEmpty) json['HostConfig'] = hostConfig;
    return json;
  }
}
```

- [ ] **Step 4: Run the model test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/container_create_config_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Write the failing client test**

Create `app/test/api/docker_api_client_create_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/api/models/container_create_config.dart';

class _Rec {
  final String path;
  final Map<String, String>? query;
  final Object? body;
  _Rec(this.path, this.query, this.body);
}

class _FakeTransport implements Transport {
  final List<_Rec> posts = [];
  int createStatus = 201;
  String createBody = '{"Id":"abc123"}';
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(_Rec(path, query, body));
    if (path == '/containers/create') return http.Response(createBody, createStatus);
    return http.Response('', 204);
  }
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  test('createContainer posts the config and returns the Id', () async {
    final t = _FakeTransport();
    final id = await DockerApiClient(t).createContainer(
        const ContainerCreateConfig(image: 'nginx'), name: 'web');
    expect(id, 'abc123');
    final rec = t.posts.single;
    expect(rec.path, '/containers/create');
    expect(rec.query, {'name': 'web'});
    expect((rec.body as Map)['Image'], 'nginx');
  });

  test('no name query when name is null/empty; non-201 throws', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).createContainer(const ContainerCreateConfig(image: 'nginx'));
    expect(t.posts.single.query, isNull);

    final t2 = _FakeTransport()..createStatus = 404..createBody = '{"message":"No such image: nginx"}';
    expect(
      () => DockerApiClient(t2).createContainer(const ContainerCreateConfig(image: 'nginx')),
      throwsA(isA<DockerApiException>()),
    );
  });
}
```

- [ ] **Step 6: Add `createContainer`**

In `app/lib/src/api/docker_api_client.dart`, add `import 'models/container_create_config.dart';` and append inside `DockerApiClient`:
```dart
  Future<String> createContainer(ContainerCreateConfig config, {String? name}) async {
    final resp = await transport.post(
      '/containers/create',
      query: (name == null || name.isEmpty) ? null : {'name': name},
      body: config.toJson(),
    );
    if (resp.statusCode != 201) throw DockerApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as Map<String, dynamic>)['Id'] as String;
  }
```

- [ ] **Step 7: Run both tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/container_create_config_test.dart test/api/docker_api_client_create_test.dart && flutter analyze`
Expected: PASS (5 tests); analyzer clean.

- [ ] **Step 8: Commit**

```bash
git add app/lib/src/api/models/container_create_config.dart app/lib/src/api/docker_api_client.dart app/test/api/models/container_create_config_test.dart app/test/api/docker_api_client_create_test.dart
git commit -m "feat(app): ContainerCreateConfig + createContainer"
```

---

## Task 2: PortMappingEditor

**Files:**
- Create: `app/lib/src/ui/widgets/port_mapping_editor.dart`
- Test: `app/test/ui/widgets/port_mapping_editor_test.dart`

**Interfaces:**
- Consumes: `PortMapping` (Task 1).
- Produces: `class PortMappingEditor extends StatefulWidget { PortMappingEditor({required void Function(List<PortMapping>) onChanged}); }`

- [ ] **Step 1: Write the failing test**

Create `app/test/ui/widgets/port_mapping_editor_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container_create_config.dart';
import 'package:docker_mobile/src/ui/widgets/port_mapping_editor.dart';

void main() {
  testWidgets('add a row, type host/container, emits a PortMapping; remove clears it', (tester) async {
    List<PortMapping> emitted = [];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PortMappingEditor(onChanged: (v) => emitted = v)),
    ));
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'host').first, '8080');
    await tester.enterText(find.widgetWithText(TextField, 'container').first, '80');
    await tester.pump();

    expect(emitted.length, 1);
    expect(emitted.single.hostPort, '8080');
    expect(emitted.single.containerPort, '80');
    expect(emitted.single.protocol, 'tcp');

    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pump();
    expect(emitted, isEmpty);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/widgets/port_mapping_editor_test.dart`
Expected: FAIL — `PortMappingEditor` undefined.

- [ ] **Step 3: Write the widget**

Create `app/lib/src/ui/widgets/port_mapping_editor.dart`:
```dart
import 'package:flutter/material.dart';

import '../../api/models/container_create_config.dart';

class PortMappingEditor extends StatefulWidget {
  final void Function(List<PortMapping>) onChanged;
  const PortMappingEditor({super.key, required this.onChanged});

  @override
  State<PortMappingEditor> createState() => _PortMappingEditorState();
}

class _PortRow {
  final TextEditingController host = TextEditingController();
  final TextEditingController container = TextEditingController();
  String proto = 'tcp';
  void dispose() {
    host.dispose();
    container.dispose();
  }
}

class _PortMappingEditorState extends State<PortMappingEditor> {
  final List<_PortRow> _rows = [];

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _emit() {
    final list = <PortMapping>[];
    for (final r in _rows) {
      final cp = r.container.text.trim();
      if (cp.isNotEmpty) {
        list.add(PortMapping(containerPort: cp, protocol: r.proto, hostPort: r.host.text.trim()));
      }
    }
    widget.onChanged(list);
  }

  void _add() => setState(() => _rows.add(_PortRow()));
  void _remove(int i) {
    setState(() => _rows.removeAt(i).dispose());
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          const Text('Ports', style: TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.add), tooltip: 'Add port', onPressed: _add),
        ]),
        for (var i = 0; i < _rows.length; i++)
          Row(children: [
            Expanded(child: TextField(
              controller: _rows[i].host,
              decoration: const InputDecoration(hintText: 'host', isDense: true),
              keyboardType: TextInputType.number,
              onChanged: (_) => _emit(),
            )),
            const SizedBox(width: 8),
            Expanded(child: TextField(
              controller: _rows[i].container,
              decoration: const InputDecoration(hintText: 'container', isDense: true),
              keyboardType: TextInputType.number,
              onChanged: (_) => _emit(),
            )),
            const SizedBox(width: 8),
            DropdownButton<String>(
              value: _rows[i].proto,
              items: const [
                DropdownMenuItem(value: 'tcp', child: Text('tcp')),
                DropdownMenuItem(value: 'udp', child: Text('udp')),
              ],
              onChanged: (v) {
                setState(() => _rows[i].proto = v ?? 'tcp');
                _emit();
              },
            ),
            IconButton(
              icon: const Icon(Icons.remove_circle_outline),
              tooltip: 'Remove',
              onPressed: () => _remove(i),
            ),
          ]),
      ],
    );
  }
}
```

- [ ] **Step 4: Run the test + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/widgets/port_mapping_editor_test.dart && flutter analyze`
Expected: PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/ui/widgets/port_mapping_editor.dart app/test/ui/widgets/port_mapping_editor_test.dart
git commit -m "feat(app): PortMappingEditor widget"
```

---

## Task 3: CreateContainerScreen (+ pull-if-missing)

**Files:**
- Create: `app/lib/src/ui/create_container_screen.dart`
- Test: `app/test/ui/create_container_screen_test.dart`

**Interfaces:**
- Consumes: `createContainer`/`startContainer`/`pullImage` (DockerApiClient), `ContainerCreateConfig`/`PortMapping` (Task 1), `PortMappingEditor` (Task 2), `KeyValueEditor`, `parseImageRef` (pull_sheet.dart), `networksProvider`/`containersProvider`/`dockerClientProvider`, `PullEvent`, `DockerApiException`.
- Produces: `class CreateContainerScreen extends ConsumerStatefulWidget { CreateContainerScreen({String? image}); }`

- [ ] **Step 1: Write the failing test**

Create `app/test/ui/create_container_screen_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/create_container_screen.dart';

class _FakeTransport implements Transport {
  final List<String> posts = [];
  int createStatus = 201;
  List<int> pullBytes = utf8.encode('{"status":"Pull complete"}\n');
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(path);
    if (path == '/containers/create') {
      // First call may 404 (image missing); later calls succeed.
      final status = createStatus;
      if (status == 404) createStatus = 201; // next create succeeds (post-pull)
      if (status == 404) return http.Response('{"message":"No such image: nginx"}', 404);
      return http.Response('{"Id":"abc"}', 201);
    }
    return http.Response('', 204);
  }
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => Stream.value(pullBytes);
}

Widget _wrap(Transport t, {String? image}) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: MaterialApp(home: CreateContainerScreen(image: image)),
    );

void main() {
  testWidgets('empty image blocks create', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pump();
    expect(find.textContaining('Image'), findsWidgets);
    expect(t.posts, isEmpty);
  });

  testWidgets('valid create (start on) posts create then start', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(_wrap(t, image: 'nginx'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(t.posts, containsAllInOrder(<String>['/containers/create', '/containers/abc/start']));
  });

  testWidgets('404 offers to pull, then retries create', (tester) async {
    final t = _FakeTransport()..createStatus = 404;
    await tester.pumpWidget(_wrap(t, image: 'nginx'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    // confirm the pull
    expect(find.textContaining('not found'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, 'Pull'));
    await tester.pumpAndSettle();
    // create was attempted twice (404 then 201)
    expect(t.posts.where((p) => p == '/containers/create').length, 2);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/create_container_screen_test.dart`
Expected: FAIL — `CreateContainerScreen` undefined.

- [ ] **Step 3: Write the screen**

Create `app/lib/src/ui/create_container_screen.dart`:
```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_create_config.dart';
import '../api/models/pull_event.dart';
import '../state/providers.dart';
import 'pull_sheet.dart' show parseImageRef;
import 'widgets/key_value_editor.dart';
import 'widgets/port_mapping_editor.dart';

class CreateContainerScreen extends ConsumerStatefulWidget {
  final String? image;
  const CreateContainerScreen({super.key, this.image});

  @override
  ConsumerState<CreateContainerScreen> createState() => _CreateContainerScreenState();
}

class _CreateContainerScreenState extends ConsumerState<CreateContainerScreen> {
  final _image = TextEditingController();
  final _name = TextEditingController();
  final _command = TextEditingController();
  final _memory = TextEditingController();
  final _cpus = TextEditingController();
  Map<String, String> _env = {};
  Map<String, String> _labels = {};
  Map<String, String> _binds = {};
  List<PortMapping> _ports = [];
  String? _restart;
  String? _network;
  bool _start = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    if (widget.image != null) _image.text = widget.image!;
  }

  @override
  void dispose() {
    _image.dispose();
    _name.dispose();
    _command.dispose();
    _memory.dispose();
    _cpus.dispose();
    super.dispose();
  }

  int? _memBytes() {
    final mb = int.tryParse(_memory.text.trim());
    return mb == null ? null : mb * 1024 * 1024;
  }

  ContainerCreateConfig _buildConfig(String image) => ContainerCreateConfig(
        image: image,
        cmd: ContainerCreateConfig.parseCommand(_command.text),
        env: _env,
        ports: _ports,
        binds: _binds,
        restartPolicy: _restart,
        labels: _labels,
        network: _network,
        memoryBytes: _memBytes(),
        cpus: double.tryParse(_cpus.text.trim()),
      );

  Future<void> _create() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    final image = _image.text.trim();
    if (image.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Image is required.')));
      return;
    }
    final config = _buildConfig(image);
    final name = _name.text.trim();

    setState(() => _busy = true);
    try {
      String id;
      try {
        id = await client.createContainer(config, name: name.isEmpty ? null : name);
      } on DockerApiException catch (e) {
        if (e.statusCode != 404 && !e.body.contains('No such image')) rethrow;
        if (!mounted) return;
        final pull = await _confirmPull(image);
        if (pull != true) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        if (!mounted) return;
        final ok = await _pullImage(image);
        if (!ok) {
          if (mounted) setState(() => _busy = false);
          return;
        }
        id = await client.createContainer(config, name: name.isEmpty ? null : name);
      }
      if (_start) await client.startContainer(id);
      ref.invalidate(containersProvider);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(content: Text('Container created.')));
      navigator.pop();
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Future<bool?> _confirmPull(String image) => showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Image not found'),
          content: Text('"$image" is not present locally. Pull it and retry?'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Pull')),
          ],
        ),
      );

  Future<bool> _pullImage(String image) async {
    final client = ref.read(dockerClientProvider);
    if (client == null) return false;
    final (img, tag) = parseImageRef(image);
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => _PullProgressDialog(stream: client.pullImage(img, tag: tag)),
    );
    return ok ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final networks = ref.watch(networksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Create container')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _image, decoration: const InputDecoration(labelText: 'Image (e.g. nginx:latest)')),
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name (optional)')),
          TextField(controller: _command, decoration: const InputDecoration(labelText: 'Command (optional, space-separated)')),
          const SizedBox(height: 8),
          DropdownButtonFormField<String?>(
            initialValue: _network,
            decoration: const InputDecoration(labelText: 'Network'),
            items: [
              const DropdownMenuItem(value: null, child: Text('(default)')),
              ...networks.maybeWhen(
                data: (list) => list.map((n) => DropdownMenuItem<String?>(value: n.name, child: Text(n.name))),
                orElse: () => const <DropdownMenuItem<String?>>[],
              ),
            ],
            onChanged: (v) => setState(() => _network = v),
          ),
          DropdownButtonFormField<String?>(
            initialValue: _restart,
            decoration: const InputDecoration(labelText: 'Restart policy'),
            items: const [
              DropdownMenuItem(value: null, child: Text('(none)')),
              DropdownMenuItem(value: 'no', child: Text('no')),
              DropdownMenuItem(value: 'on-failure', child: Text('on-failure')),
              DropdownMenuItem(value: 'always', child: Text('always')),
              DropdownMenuItem(value: 'unless-stopped', child: Text('unless-stopped')),
            ],
            onChanged: (v) => setState(() => _restart = v),
          ),
          Row(children: [
            Expanded(child: TextField(controller: _memory, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Memory (MB)'))),
            const SizedBox(width: 8),
            Expanded(child: TextField(controller: _cpus, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'CPUs'))),
          ]),
          const SizedBox(height: 12),
          KeyValueEditor(title: 'Environment', onChanged: (m) => _env = m),
          const SizedBox(height: 12),
          PortMappingEditor(onChanged: (p) => _ports = p),
          const SizedBox(height: 12),
          KeyValueEditor(title: 'Volumes (host → container)', onChanged: (m) => _binds = m),
          const SizedBox(height: 12),
          KeyValueEditor(title: 'Labels', onChanged: (m) => _labels = m),
          const SizedBox(height: 12),
          SwitchListTile(title: const Text('Start after create'), value: _start, onChanged: (v) => setState(() => _start = v)),
          const SizedBox(height: 16),
          FilledButton(onPressed: _busy ? null : _create, child: const Text('Create')),
        ],
      ),
    );
  }
}

class _PullProgressDialog extends StatefulWidget {
  final Stream<PullEvent> stream;
  const _PullProgressDialog({required this.stream});
  @override
  State<_PullProgressDialog> createState() => _PullProgressDialogState();
}

class _PullProgressDialogState extends State<_PullProgressDialog> {
  StreamSubscription<PullEvent>? _sub;
  String _status = 'Pulling…';
  String? _error;

  @override
  void initState() {
    super.initState();
    _sub = widget.stream.listen(
      (e) => setState(() {
        if (e.error != null) {
          _error = e.error;
        } else {
          _status = e.status;
        }
      }),
      onError: (Object e) {
        if (mounted) Navigator.of(context).pop(false);
      },
      onDone: () {
        if (mounted) Navigator.of(context).pop(_error == null);
      },
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Pulling image'),
        content: Row(children: [
          const CircularProgressIndicator(),
          const SizedBox(width: 16),
          Expanded(child: Text(_error ?? _status)),
        ]),
      );
}
```

- [ ] **Step 4: Run the test + analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/create_container_screen_test.dart && flutter analyze && flutter test`
Expected: the new test passes (3 cases); analyzer clean; full suite green.
NOTE: `DropdownButtonFormField` uses `initialValue:` on Flutter 3.44 (the old `value:` is deprecated/removed in this SDK). If analyze flags `initialValue`, switch that one parameter to `value:` — keep everything else.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/ui/create_container_screen.dart app/test/ui/create_container_screen_test.dart
git commit -m "feat(app): CreateContainerScreen with pull-if-missing"
```

---

## Task 4: Entry points (Containers FAB + Image Run)

**Files:**
- Modify: `app/lib/src/ui/containers_screen.dart`
- Modify: `app/lib/src/ui/image_detail_screen.dart`
- Test: `app/test/ui/create_entrypoints_test.dart`

**Interfaces:**
- Consumes: `CreateContainerScreen` (Task 3).
- Produces: a create FAB on `ContainersScreen`; a Run button on `ImageDetailScreen`.

- [ ] **Step 1: Write the failing test**

Create `app/test/ui/create_entrypoints_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/containers_screen.dart';
import 'package:docker_mobile/src/ui/image_detail_screen.dart';
import 'package:docker_mobile/src/ui/create_container_screen.dart';

class _FakeTransport implements Transport {
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path.contains('/history')) return http.Response('[]', 200);
    if (path.startsWith('/images/')) {
      return http.Response('{"Architecture":"amd64","Os":"linux","Size":1,"Created":"2024","Config":{}}', 200);
    }
    return http.Response('[]', 200); // containers list, networks
  }
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async => http.Response('', 204);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

Widget _wrap(Widget child) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => _FakeTransport())],
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('Containers FAB opens the create screen', (tester) async {
    await tester.pumpWidget(_wrap(const ContainersScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(CreateContainerScreen), findsOneWidget);
  });

  testWidgets('Image Run opens the create screen pre-filled', (tester) async {
    await tester.pumpWidget(_wrap(const ImageDetailScreen(imageId: 'sha', title: 'nginx:latest')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await tester.pumpAndSettle();
    expect(find.byType(CreateContainerScreen), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Image (e.g. nginx:latest)'), findsOneWidget);
    expect(find.text('nginx:latest'), findsWidgets); // pre-filled image
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/create_entrypoints_test.dart`
Expected: FAIL — no FAB / no Run button.

- [ ] **Step 3: Add the Containers FAB**

In `app/lib/src/ui/containers_screen.dart`, add `import 'create_container_screen.dart';` and add a `floatingActionButton` to the `Scaffold` (alongside the existing `appBar`/`body`):
```dart
      floatingActionButton: FloatingActionButton(
        tooltip: 'Create container',
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CreateContainerScreen()),
        ),
        child: const Icon(Icons.add),
      ),
```

- [ ] **Step 4: Add the Image Run button**

In `app/lib/src/ui/image_detail_screen.dart`, add `import 'create_container_screen.dart';` and add a `Run` button as the FIRST child of the existing `Wrap(spacing: 8, children: [...])` (before Tag):
```dart
              FilledButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => CreateContainerScreen(image: title)),
                ),
                child: const Text('Run'),
              ),
```

- [ ] **Step 5: Run the test + analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/create_entrypoints_test.dart && flutter analyze && flutter test`
Expected: the new test passes; analyzer clean; **all** app tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/ui/containers_screen.dart app/lib/src/ui/image_detail_screen.dart app/test/ui/create_entrypoints_test.dart
git commit -m "feat(app): create-container entry points (Containers FAB + image Run)"
```

---

## Self-Review

**1. Spec coverage:**
- `ContainerCreateConfig` (toJson shapes, parseCommand, omit-empty) + `PortMapping` → Task 1. ✓
- `createContainer` (201→Id, name query, non-201 throws) → Task 1. ✓
- `PortMappingEditor` → Task 2. ✓
- `CreateContainerScreen` (rich fields, create→start, validation, pull-if-missing) → Task 3. ✓
- Reuse `KeyValueEditor`/`networksProvider`/`pullImage`/`parseImageRef` → Task 3. ✓
- Entry points (Containers FAB + Image Run pre-filled) → Task 4. ✓
- Out of scope (healthcheck/caps/multi-net/edit/compose/build) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete. The `DropdownButtonFormField` `initialValue`-vs-`value` SDK note is an explicit, bounded adaptation instruction (Flutter 3.44 renamed it), not a placeholder.

**3. Type consistency:** `ContainerCreateConfig({image, cmd, env, ports, binds, restartPolicy, labels, network, memoryBytes, cpus})` + `PortMapping({containerPort, protocol, hostPort})` + `parseCommand` (Task 1) used identically in Tasks 2/3. `createContainer(config, {name})` (Task 1) called in Task 3. `PortMappingEditor({onChanged: List<PortMapping>})` (Task 2) used in Task 3. `KeyValueEditor({title, onChanged})` + `parseImageRef` + `networksProvider` + `pullImage`/`startContainer`/`containersProvider` are existing symbols used as defined. `CreateContainerScreen({image})` (Task 3) used by both entry points (Task 4). ✓
