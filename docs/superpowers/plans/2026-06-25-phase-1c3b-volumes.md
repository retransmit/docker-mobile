# Phase 1C-3b — Volumes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Volume management — a Volumes tab with list, detail, create (name + driver + labels + driver-options), remove (with force), and prune.

**Architecture:** App-only, using existing `Transport` methods (get/post/delete) and the existing `KeyValueEditor`. Add a model, `DockerApiClient` volume methods, three screens, and a Volumes bottom-nav tab. Mirrors the networks slice (simpler — no IPAM).

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `http` (all existing).

## Global Constraints

- **App-only slice:** no agent changes; NO new `Transport` methods (use existing get/post/delete).
- **Identity:** volumes are keyed by **Name** (no hash id); detail/remove use the name.
- **Status codes:** create = `201`; remove = `204`; prune = `200`; list/inspect = `200`; non-success → `DockerApiException(statusCode, body)` (a `409` volume-in-use on remove surfaced as such).
- **Create body:** `{Name, Driver}` plus `Labels`/`DriverOpts` only when non-empty.
- **Async + controller discipline:** capture `messenger`/`navigator` BEFORE any `await`; `mounted`-guard every post-`await` `setState`; dialogs/forms that own `TextEditingController`s are `StatefulWidget`s that dispose them in `State.dispose` (NEVER `try/finally` around `showDialog`).
- **Nav:** add a Volumes `NavigationDestination` (icon `Icons.storage`); now Containers | Images | Networks | Volumes.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"`.
- **Discipline:** TDD, DRY, YAGNI, frequent commits, commit messages with NO `Co-Authored-By` trailer. Repo local/private on a feature branch.

---

## File Structure

```
app/lib/src/api/models/docker_volume.dart        # DockerVolume
app/lib/src/api/docker_api_client.dart            # + 5 volume methods
app/lib/src/state/providers.dart                  # + volumes providers
app/lib/src/ui/volume_create_sheet.dart           # VolumeCreateSheet
app/lib/src/ui/volume_detail_screen.dart          # VolumeDetailScreen
app/lib/src/ui/volumes_screen.dart                # VolumesScreen
app/lib/src/ui/home_screen.dart                   # + Volumes tab
app/test/...                                        # mirrors the above
```

---

## Task 1: DockerVolume model

**Files:**
- Create: `app/lib/src/api/models/docker_volume.dart`
- Test: `app/test/api/models/docker_volume_test.dart`

**Interfaces:**
- Produces: `class DockerVolume { final String name, driver, mountpoint, createdAt, scope; final Map<String,String> labels, options; factory DockerVolume.fromJson(Map); }`

- [ ] **Step 1: Write the failing test**

Create `app/test/api/models/docker_volume_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_volume.dart';

void main() {
  test('parses a volume', () {
    final v = DockerVolume.fromJson({
      'Name': 'data',
      'Driver': 'local',
      'Mountpoint': '/var/lib/docker/volumes/data/_data',
      'CreatedAt': '2026-01-02T03:04:05Z',
      'Scope': 'local',
      'Labels': {'env': 'prod'},
      'Options': {'type': 'nfs'},
    });
    expect(v.name, 'data');
    expect(v.driver, 'local');
    expect(v.mountpoint, '/var/lib/docker/volumes/data/_data');
    expect(v.createdAt, '2026-01-02T03:04:05Z');
    expect(v.scope, 'local');
    expect(v.labels, {'env': 'prod'});
    expect(v.options, {'type': 'nfs'});
  });

  test('tolerates missing/null fields', () {
    final v = DockerVolume.fromJson({'Name': 'x', 'Labels': null, 'Options': null});
    expect(v.driver, '');
    expect(v.mountpoint, '');
    expect(v.labels, isEmpty);
    expect(v.options, isEmpty);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/docker_volume_test.dart`
Expected: FAIL — `DockerVolume` undefined.

- [ ] **Step 3: Write the model**

Create `app/lib/src/api/models/docker_volume.dart`:
```dart
class DockerVolume {
  final String name;
  final String driver;
  final String mountpoint;
  final String createdAt;
  final String scope;
  final Map<String, String> labels;
  final Map<String, String> options;

  const DockerVolume({
    required this.name,
    required this.driver,
    required this.mountpoint,
    required this.createdAt,
    required this.scope,
    required this.labels,
    required this.options,
  });

  factory DockerVolume.fromJson(Map<String, dynamic> json) => DockerVolume(
        name: json['Name'] as String? ?? '',
        driver: json['Driver'] as String? ?? '',
        mountpoint: json['Mountpoint'] as String? ?? '',
        createdAt: json['CreatedAt'] as String? ?? '',
        scope: json['Scope'] as String? ?? '',
        labels: ((json['Labels'] as Map<String, dynamic>?) ?? const {}).map((k, v) => MapEntry(k, '$v')),
        options: ((json['Options'] as Map<String, dynamic>?) ?? const {}).map((k, v) => MapEntry(k, '$v')),
      );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/docker_volume_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/models/docker_volume.dart app/test/api/models/docker_volume_test.dart
git commit -m "feat(app): DockerVolume model"
```

---

## Task 2: DockerApiClient — volume methods

**Files:**
- Modify: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/docker_api_client_volumes_test.dart`

**Interfaces:**
- Consumes: `Transport` (existing), `DockerVolume` (Task 1).
- Produces on `DockerApiClient`: `listVolumes()`, `inspectVolume(name)`, `createVolume({...})`, `removeVolume(name, {force})`, `pruneVolumes()`.

- [ ] **Step 1: Write the failing test**

Create `app/test/api/docker_api_client_volumes_test.dart`:
```dart
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
  Object? lastPostBody;
  http.Response getResponse = http.Response('{"Volumes":[]}', 200);
  int postStatus = 201;
  int deleteStatus = 204;

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    calls.add(_Rec('get', path, query));
    return getResponse;
  }
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    calls.add(_Rec('post', path, query));
    lastPostBody = body;
    return http.Response('{"Name":"data","Driver":"local"}', postStatus);
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
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  test('listVolumes parses the Volumes array', () async {
    final t = _FakeTransport()
      ..getResponse = http.Response('{"Volumes":[{"Name":"data","Driver":"local"}]}', 200);
    final vols = await DockerApiClient(t).listVolumes();
    expect(vols.single.name, 'data');
    expect(t.calls.single.path, '/volumes');
  });

  test('createVolume posts body, omitting empty Labels/DriverOpts, and returns the volume', () async {
    final t = _FakeTransport();
    final v = await DockerApiClient(t).createVolume(name: 'data', labels: const {'env': 'prod'});
    expect(v.name, 'data');
    expect(t.calls.last.path, '/volumes/create');
    final body = t.lastPostBody as Map<String, dynamic>;
    expect(body['Name'], 'data');
    expect(body['Driver'], 'local');
    expect(body['Labels'], {'env': 'prod'});
    expect(body.containsKey('DriverOpts'), isFalse);
  });

  test('removeVolume deletes with force', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).removeVolume('data', force: true);
    expect(t.calls.last.verb, 'delete');
    expect(t.calls.last.path, '/volumes/data');
    expect(t.calls.last.query, {'force': 'true'});
  });

  test('a 409 on remove throws DockerApiException', () async {
    final t = _FakeTransport()..deleteStatus = 409;
    expect(() => DockerApiClient(t).removeVolume('data'), throwsA(isA<DockerApiException>()));
  });

  test('pruneVolumes posts to /volumes/prune', () async {
    final t = _FakeTransport()..postStatus = 200;
    await DockerApiClient(t).pruneVolumes();
    expect(t.calls.last.path, '/volumes/prune');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/docker_api_client_volumes_test.dart`
Expected: FAIL — volume methods undefined.

- [ ] **Step 3: Add the methods**

In `app/lib/src/api/docker_api_client.dart`, add `import 'models/docker_volume.dart';`, then append inside `DockerApiClient`:
```dart
  Future<List<DockerVolume>> listVolumes() async {
    final resp = await transport.get('/volumes');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    final list = (jsonDecode(resp.body) as Map<String, dynamic>)['Volumes'] as List? ?? const [];
    return list.map((e) => DockerVolume.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<DockerVolume> inspectVolume(String name) async {
    final resp = await transport.get('/volumes/$name');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return DockerVolume.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<DockerVolume> createVolume({
    required String name,
    String driver = 'local',
    Map<String, String> labels = const {},
    Map<String, String> driverOpts = const {},
  }) async {
    final body = <String, dynamic>{'Name': name, 'Driver': driver};
    if (labels.isNotEmpty) body['Labels'] = labels;
    if (driverOpts.isNotEmpty) body['DriverOpts'] = driverOpts;
    final resp = await transport.post('/volumes/create', body: body);
    if (resp.statusCode != 201) throw DockerApiException(resp.statusCode, resp.body);
    return DockerVolume.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> removeVolume(String name, {bool force = false}) async =>
      _ensure(await transport.delete('/volumes/$name', query: {'force': '$force'}), ok: const {204});

  Future<void> pruneVolumes() async =>
      _ensure(await transport.post('/volumes/prune'), ok: const {200});
```

- [ ] **Step 4: Run the tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/ && flutter analyze`
Expected: PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/docker_api_client.dart app/test/api/docker_api_client_volumes_test.dart
git commit -m "feat(app): DockerApiClient volume methods (list/inspect/create/remove/prune)"
```

---

## Task 3: VolumeCreateSheet + volumesProvider

**Files:**
- Modify: `app/lib/src/state/providers.dart`
- Create: `app/lib/src/ui/volume_create_sheet.dart`
- Test: `app/test/ui/volume_create_sheet_test.dart`

**Interfaces:**
- Consumes: `createVolume` (Task 2), `KeyValueEditor` (existing), `dockerClientProvider`.
- Produces: `volumesProvider = FutureProvider<List<DockerVolume>>`; `class VolumeCreateSheet extends ConsumerStatefulWidget { const VolumeCreateSheet({super.key}); }`.

- [ ] **Step 1: Add volumesProvider**

In `app/lib/src/state/providers.dart`, add `import '../api/models/docker_volume.dart';` and:
```dart
final volumesProvider = FutureProvider<List<DockerVolume>>((ref) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.listVolumes();
});
```

- [ ] **Step 2: Write the failing widget test**

Create `app/test/ui/volume_create_sheet_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/volume_create_sheet.dart';

class _FakeTransport implements Transport {
  Map<String, dynamic>? createBody;
  int createStatus = 201;
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{"Volumes":[]}', 200);
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    if (path == '/volumes/create') createBody = body as Map<String, dynamic>;
    return http.Response('{"Name":"data","Driver":"local"}', createStatus);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: VolumeCreateSheet()),
    );

void main() {
  testWidgets('fills the form and creates a volume with a label', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'data');
    await tester.tap(find.byIcon(Icons.add).first); // Labels editor
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'key'), 'env');
    await tester.enterText(find.widgetWithText(TextField, 'value'), 'prod');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(t.createBody, isNotNull);
    expect(t.createBody!['Name'], 'data');
    expect(t.createBody!['Driver'], 'local');
    expect(t.createBody!['Labels'], {'env': 'prod'});
  });

  testWidgets('Create is disabled until a name is entered', (tester) async {
    await tester.pumpWidget(_wrap(_FakeTransport()));
    await tester.pumpAndSettle();
    final btn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'));
    expect(btn.onPressed, isNull);
  });

  testWidgets('a failing create shows an error snackbar without crashing', (tester) async {
    final t = _FakeTransport()..createStatus = 500;
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'data');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed'), findsOneWidget);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/volume_create_sheet_test.dart`
Expected: FAIL — `VolumeCreateSheet` undefined.

- [ ] **Step 4: Write VolumeCreateSheet**

Create `app/lib/src/ui/volume_create_sheet.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'widgets/key_value_editor.dart';

class VolumeCreateSheet extends ConsumerStatefulWidget {
  const VolumeCreateSheet({super.key});

  @override
  ConsumerState<VolumeCreateSheet> createState() => _VolumeCreateSheetState();
}

class _VolumeCreateSheetState extends ConsumerState<VolumeCreateSheet> {
  final _name = TextEditingController();
  final _driver = TextEditingController(text: 'local');
  Map<String, String> _labels = {};
  Map<String, String> _opts = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _name.dispose();
    _driver.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await client.createVolume(
        name: _name.text.trim(),
        driver: _driver.text.trim().isEmpty ? 'local' : _driver.text.trim(),
        labels: _labels,
        driverOpts: _opts,
      );
      ref.invalidate(volumesProvider);
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Text('Volume created')));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = !_busy && _name.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Create volume')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          TextField(controller: _driver, decoration: const InputDecoration(labelText: 'Driver')),
          const Divider(),
          KeyValueEditor(title: 'Labels', onChanged: (m) => _labels = m),
          const Divider(),
          KeyValueEditor(title: 'Driver options', onChanged: (m) => _opts = m),
          const SizedBox(height: 16),
          FilledButton(onPressed: canCreate ? _create : null, child: const Text('Create')),
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/volume_create_sheet_test.dart`
Expected: PASS (all three).

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/state/providers.dart app/lib/src/ui/volume_create_sheet.dart app/test/ui/volume_create_sheet_test.dart
git commit -m "feat(app): VolumeCreateSheet (name/driver/labels/options)"
```

---

## Task 4: VolumeDetailScreen + volumeDetailProvider

**Files:**
- Modify: `app/lib/src/state/providers.dart`
- Create: `app/lib/src/ui/volume_detail_screen.dart`
- Test: `app/test/ui/volume_detail_screen_test.dart`

**Interfaces:**
- Consumes: `inspectVolume`/`removeVolume` (Task 2), `DockerVolume` (Task 1), `volumesProvider` (Task 3), `dockerClientProvider`.
- Produces: `volumeDetailProvider`; `class VolumeDetailScreen extends ConsumerWidget { const VolumeDetailScreen({required this.volumeName}); }`.

- [ ] **Step 1: Add the provider**

In `app/lib/src/state/providers.dart`, add:
```dart
final volumeDetailProvider = FutureProvider.family<DockerVolume, String>((ref, name) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.inspectVolume(name);
});
```

- [ ] **Step 2: Write the failing widget test**

Create `app/test/ui/volume_detail_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/volume_detail_screen.dart';

class _FakeTransport implements Transport {
  final List<String> deletes = [];
  final List<Map<String, String>?> deleteQueries = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response(
        '{"Name":"data","Driver":"local","Mountpoint":"/var/lib/docker/volumes/data/_data","Scope":"local","Labels":{"env":"prod"}}',
        200,
      );
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    deletes.add(path);
    deleteQueries.add(query);
    return http.Response('', 204);
  }
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

Future<void> _open(WidgetTester tester, Transport t) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [transportProvider.overrideWith((ref) => t)],
    child: MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(child: ElevatedButton(
            onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => const VolumeDetailScreen(volumeName: 'data'))),
            child: const Text('open'),
          )),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders detail and removes', (tester) async {
    final t = _FakeTransport();
    await _open(tester, t);

    expect(find.text('data'), findsOneWidget); // app bar title
    expect(find.textContaining('/var/lib/docker/volumes/data/_data'), findsWidgets);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove')); // confirm
    await tester.pumpAndSettle();

    expect(t.deletes, contains('/volumes/data'));
    expect(find.text('open'), findsOneWidget); // popped back
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/volume_detail_screen_test.dart`
Expected: FAIL — `VolumeDetailScreen` undefined.

- [ ] **Step 4: Write VolumeDetailScreen**

Create `app/lib/src/ui/volume_detail_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

class VolumeDetailScreen extends ConsumerWidget {
  final String volumeName;
  const VolumeDetailScreen({super.key, required this.volumeName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(volumeDetailProvider(volumeName));
    return Scaffold(
      appBar: AppBar(title: Text(volumeName)),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (v) {
          final client = ref.read(dockerClientProvider);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('${v.driver} · ${v.scope}'),
              Text('Mountpoint: ${v.mountpoint}'),
              if (v.createdAt.isNotEmpty) Text('Created: ${v.createdAt}'),
              if (v.labels.isNotEmpty) ...[
                const Divider(),
                const Text('Labels', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final e in v.labels.entries) Text('${e.key} = ${e.value}'),
              ],
              if (v.options.isNotEmpty) ...[
                const Divider(),
                const Text('Options', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final e in v.options.entries) Text('${e.key} = ${e.value}'),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final navigator = Navigator.of(context);
                  final force = await _removeDialog(context);
                  if (force == null || client == null || !context.mounted) return;
                  try {
                    await client.removeVolume(volumeName, force: force);
                    ref.invalidate(volumesProvider);
                    navigator.pop();
                    messenger.showSnackBar(const SnackBar(content: Text('Removed')));
                  } catch (e) {
                    messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
                  }
                },
                child: const Text('Remove'),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Returns the force flag, or null if cancelled.
Future<bool?> _removeDialog(BuildContext context) {
  var force = false;
  return showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('Remove volume?'),
        content: SwitchListTile(
          title: const Text('Force'),
          value: force,
          onChanged: (v) => setState(() => force = v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, force), child: const Text('Remove')),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/volume_detail_screen_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/state/providers.dart app/lib/src/ui/volume_detail_screen.dart app/test/ui/volume_detail_screen_test.dart
git commit -m "feat(app): VolumeDetailScreen (detail + remove with force)"
```

---

## Task 5: VolumesScreen + HomeScreen Volumes tab

**Files:**
- Create: `app/lib/src/ui/volumes_screen.dart`
- Modify: `app/lib/src/ui/home_screen.dart`
- Test: `app/test/ui/volumes_screen_test.dart`
- Modify: `app/test/ui/home_screen_test.dart`

**Interfaces:**
- Consumes: `volumesProvider` (Task 3), `pruneVolumes` (Task 2), `VolumeCreateSheet` (Task 3), `VolumeDetailScreen` (Task 4).
- Produces: `class VolumesScreen extends ConsumerWidget`; `HomeScreen` gains a Volumes tab.

- [ ] **Step 1: Write the failing test**

Create `app/test/ui/volumes_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/volumes_screen.dart';

class _FakeTransport implements Transport {
  final List<String> posts = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async =>
      http.Response('{"Volumes":[{"Name":"data","Driver":"local","Mountpoint":"/mnt/data"}]}', 200);
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(path);
    return http.Response('', 200);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  testWidgets('lists volumes and confirms Prune', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: VolumesScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('data'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.cleaning_services));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Prune'));
    await tester.pumpAndSettle();
    expect(t.posts, contains('/volumes/prune'));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/volumes_screen_test.dart`
Expected: FAIL — `VolumesScreen` undefined.

- [ ] **Step 3: Write VolumesScreen**

Create `app/lib/src/ui/volumes_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'volume_create_sheet.dart';
import 'volume_detail_screen.dart';

class VolumesScreen extends ConsumerWidget {
  const VolumesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final volumes = ref.watch(volumesProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Volumes'),
        actions: [
          IconButton(
            tooltip: 'Create',
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const VolumeCreateSheet())),
          ),
          IconButton(tooltip: 'Prune', icon: const Icon(Icons.cleaning_services), onPressed: () => _prune(context, ref)),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(volumesProvider)),
        ],
      ),
      body: volumes.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => ListView.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final v = list[i];
            return ListTile(
              leading: const Icon(Icons.storage),
              title: Text(v.name),
              subtitle: Text('${v.driver} · ${v.mountpoint}'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => VolumeDetailScreen(volumeName: v.name))),
            );
          },
        ),
      ),
    );
  }

  Future<void> _prune(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Prune volumes'),
        content: const Text('Remove all unused (anonymous) volumes?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Prune')),
        ],
      ),
    );
    if (ok != true) return;
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    try {
      await client.pruneVolumes();
      ref.invalidate(volumesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Pruned')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}
```

- [ ] **Step 4: Add the Volumes tab to HomeScreen**

In `app/lib/src/ui/home_screen.dart`, add `import 'volumes_screen.dart';`, add `VolumesScreen()` to the `IndexedStack` children, and add a fourth `NavigationDestination`:
```dart
      body: IndexedStack(
        index: _index,
        children: const [ContainersScreen(), ImagesScreen(), NetworksScreen(), VolumesScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inventory), label: 'Containers'),
          NavigationDestination(icon: Icon(Icons.layers), label: 'Images'),
          NavigationDestination(icon: Icon(Icons.hub), label: 'Networks'),
          NavigationDestination(icon: Icon(Icons.storage), label: 'Volumes'),
        ],
      ),
```

- [ ] **Step 5: Extend the HomeScreen test for the Volumes tab**

In `app/test/ui/home_screen_test.dart`, add after the existing Networks-tab assertion (`expect(bar().selectedIndex, 2);`):
```dart
    await tester.tap(find.byIcon(Icons.storage)); // Volumes destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 3);
```
(Keep the final Containers re-select assertion last.)

- [ ] **Step 6: Run analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; **all** app tests pass.

- [ ] **Step 7: Commit**

```bash
git add app/lib/src/ui/volumes_screen.dart app/lib/src/ui/home_screen.dart app/test/ui/volumes_screen_test.dart app/test/ui/home_screen_test.dart
git commit -m "feat(app): VolumesScreen + Volumes bottom-nav tab"
```

---

## Self-Review

**1. Spec coverage:**
- `DockerVolume` model (one shape, null-tolerant) → Task 1. ✓
- Client list/inspect/create(omit empty)/remove(force)/prune + status codes → Task 2. ✓
- `VolumeCreateSheet` (name/driver/labels/opts, name-validated, mounted-guarded) + `volumesProvider` → Task 3. ✓
- `VolumeDetailScreen` (detail + remove-with-force confirm) + `volumeDetailProvider` → Task 4. ✓
- `VolumesScreen` (list/create/prune/refresh/tap) + Volumes tab → Task 5. ✓
- Error handling (409 via snackbar, name validation, controller disposal, async-gap) → Tasks 2/3/4/5. ✓
- Out of scope (system, UsageData) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code step is complete.

**3. Type consistency:** `DockerVolume` (Task 1) used by Task 2/3/4/5. `createVolume({name, driver, labels, driverOpts})`/`removeVolume(name,{force})`/`pruneVolumes()` (Task 2) called from Tasks 3/4/5. `volumesProvider` (Task 3) + `volumeDetailProvider` (Task 4) watched by their screens. `VolumeCreateSheet()`/`VolumeDetailScreen(volumeName)`/`VolumesScreen()` constructors match call sites. `_removeDialog` returns `bool?` (force or null). ✓
