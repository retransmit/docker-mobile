# Phase 1C-3a — Networks — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Network management — a Networks tab with list, detail, rich create (driver + dynamic IPAM + labels + options), remove, and prune — plus a reusable `KeyValueEditor` widget.

**Architecture:** App-only, using existing `Transport` methods (get/post/delete). Add a reusable key/value editor, network models, `DockerApiClient` network methods, three screens, and a Networks bottom-nav tab.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `http` (all existing).

## Global Constraints

- **App-only slice:** no agent changes; no new `Transport` methods (use existing get/post/delete).
- **Status codes:** create = `201`; remove = `204`; prune = `200`; list/inspect = `200`; non-success → `DockerApiException(statusCode, body)` (a `403` removing predefined `bridge/host/none` is surfaced as such).
- **Create body:** `POST /networks/create` with `{Name, Driver, Internal, Attachable, EnableIPv6}`; include `IPAM:{Driver:'default', Config:[…]}` only when there is ≥1 IPAM row (each config includes only its non-empty Subnet/Gateway/IPRange keys); include `Labels`/`Options` only when non-empty.
- **Dialog/controller discipline:** any widget owning `TextEditingController`s is a `StatefulWidget` that disposes them in `State.dispose` — NEVER a `try/finally` around `showDialog`.
- **Nav:** add a Networks destination to `HomeScreen` (now Containers | Images | Networks); the Networks icon is `Icons.hub`.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"`.
- **Discipline:** TDD, DRY, YAGNI, frequent commits, commit messages with NO `Co-Authored-By` trailer. Repo local/private on a feature branch.

---

## File Structure

```
app/lib/src/ui/widgets/key_value_editor.dart      # KeyValueEditor
app/lib/src/api/models/docker_network.dart          # DockerNetwork + IpamConfig + NetworkDetail
app/lib/src/api/docker_api_client.dart              # + 5 network methods
app/lib/src/state/providers.dart                    # + networks providers
app/lib/src/ui/network_create_sheet.dart            # NetworkCreateSheet
app/lib/src/ui/network_detail_screen.dart           # NetworkDetailScreen
app/lib/src/ui/networks_screen.dart                 # NetworksScreen
app/lib/src/ui/home_screen.dart                     # + Networks tab
app/test/...                                          # mirrors the above
```

---

## Task 1: KeyValueEditor widget

**Files:**
- Create: `app/lib/src/ui/widgets/key_value_editor.dart`
- Test: `app/test/ui/widgets/key_value_editor_test.dart`

**Interfaces:**
- Produces: `class KeyValueEditor extends StatefulWidget { final String title; final void Function(Map<String,String>) onChanged; const KeyValueEditor({super.key, required this.title, required this.onChanged}); }` — a titled list of key/value rows with Add/remove; calls `onChanged` with the current map (non-empty keys only) on any change.

- [ ] **Step 1: Write the failing test**

Create `app/test/ui/widgets/key_value_editor_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/ui/widgets/key_value_editor.dart';

void main() {
  testWidgets('adds a row, emits the typed key/value, and removes it', (tester) async {
    Map<String, String> emitted = {};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KeyValueEditor(title: 'Labels', onChanged: (m) => emitted = m),
      ),
    ));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'key'), 'env');
    await tester.enterText(find.widgetWithText(TextField, 'value'), 'prod');
    await tester.pump();
    expect(emitted, {'env': 'prod'});

    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pumpAndSettle();
    expect(emitted, isEmpty);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/widgets/key_value_editor_test.dart`
Expected: FAIL — `KeyValueEditor` undefined.

- [ ] **Step 3: Write the widget**

Create `app/lib/src/ui/widgets/key_value_editor.dart`:
```dart
import 'package:flutter/material.dart';

class KeyValueEditor extends StatefulWidget {
  final String title;
  final void Function(Map<String, String>) onChanged;
  const KeyValueEditor({super.key, required this.title, required this.onChanged});

  @override
  State<KeyValueEditor> createState() => _KeyValueEditorState();
}

class _KvRow {
  final TextEditingController key = TextEditingController();
  final TextEditingController value = TextEditingController();
  void dispose() {
    key.dispose();
    value.dispose();
  }
}

class _KeyValueEditorState extends State<KeyValueEditor> {
  final List<_KvRow> _rows = [];

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _emit() {
    final map = <String, String>{};
    for (final r in _rows) {
      final k = r.key.text.trim();
      if (k.isNotEmpty) map[k] = r.value.text;
    }
    widget.onChanged(map);
  }

  void _add() => setState(() => _rows.add(_KvRow()));

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
          Text(widget.title, style: const TextStyle(fontWeight: FontWeight.bold)),
          const Spacer(),
          IconButton(icon: const Icon(Icons.add), tooltip: 'Add', onPressed: _add),
        ]),
        for (var i = 0; i < _rows.length; i++)
          Row(children: [
            Expanded(child: TextField(
              controller: _rows[i].key,
              decoration: const InputDecoration(hintText: 'key', isDense: true),
              onChanged: (_) => _emit(),
            )),
            const SizedBox(width: 8),
            Expanded(child: TextField(
              controller: _rows[i].value,
              decoration: const InputDecoration(hintText: 'value', isDense: true),
              onChanged: (_) => _emit(),
            )),
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

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/widgets/key_value_editor_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/ui/widgets/key_value_editor.dart app/test/ui/widgets/key_value_editor_test.dart
git commit -m "feat(app): reusable KeyValueEditor widget"
```

---

## Task 2: Network models

**Files:**
- Create: `app/lib/src/api/models/docker_network.dart`
- Test: `app/test/api/models/docker_network_test.dart`

**Interfaces:**
- Produces:
  - `class DockerNetwork { final String id, name, driver, scope; factory DockerNetwork.fromJson(Map); }`
  - `class IpamConfig { final String? subnet, gateway, ipRange; const IpamConfig({this.subnet, this.gateway, this.ipRange}); factory IpamConfig.fromJson(Map); }`
  - `class NetworkContainer { final String name, ipv4; const NetworkContainer({required this.name, required this.ipv4}); }`
  - `class NetworkDetail { final String id, name, driver, scope, ipamDriver; final bool internal, attachable, enableIPv6; final List<IpamConfig> ipam; final List<NetworkContainer> containers; final Map<String,String> labels, options; factory NetworkDetail.fromJson(Map); }`

- [ ] **Step 1: Write the failing test**

Create `app/test/api/models/docker_network_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_network.dart';

void main() {
  test('DockerNetwork parses a /networks element', () {
    final n = DockerNetwork.fromJson({'Id': 'n1', 'Name': 'bridge', 'Driver': 'bridge', 'Scope': 'local'});
    expect(n.id, 'n1');
    expect(n.name, 'bridge');
    expect(n.driver, 'bridge');
    expect(n.scope, 'local');
  });

  test('NetworkDetail parses IPAM, containers, labels', () {
    final d = NetworkDetail.fromJson({
      'Id': 'n1',
      'Name': 'mynet',
      'Driver': 'bridge',
      'Scope': 'local',
      'Internal': true,
      'Attachable': false,
      'EnableIPv6': false,
      'IPAM': {
        'Driver': 'default',
        'Config': [{'Subnet': '10.0.0.0/24', 'Gateway': '10.0.0.1'}],
      },
      'Containers': {
        'abc123': {'Name': 'web', 'IPv4Address': '10.0.0.2/24'},
      },
      'Labels': {'env': 'prod'},
      'Options': {'com.docker.network.bridge.name': 'br0'},
    });
    expect(d.name, 'mynet');
    expect(d.internal, isTrue);
    expect(d.ipamDriver, 'default');
    expect(d.ipam.single.subnet, '10.0.0.0/24');
    expect(d.ipam.single.gateway, '10.0.0.1');
    expect(d.containers.single.name, 'web');
    expect(d.containers.single.ipv4, '10.0.0.2/24');
    expect(d.labels, {'env': 'prod'});
    expect(d.options['com.docker.network.bridge.name'], 'br0');
  });

  test('NetworkDetail tolerates missing nested fields', () {
    final d = NetworkDetail.fromJson({'Id': 'x', 'Name': 'y'});
    expect(d.ipam, isEmpty);
    expect(d.containers, isEmpty);
    expect(d.labels, isEmpty);
    expect(d.internal, isFalse);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/docker_network_test.dart`
Expected: FAIL — models undefined.

- [ ] **Step 3: Write the model**

Create `app/lib/src/api/models/docker_network.dart`:
```dart
class DockerNetwork {
  final String id;
  final String name;
  final String driver;
  final String scope;
  const DockerNetwork({required this.id, required this.name, required this.driver, required this.scope});

  factory DockerNetwork.fromJson(Map<String, dynamic> json) => DockerNetwork(
        id: json['Id'] as String? ?? '',
        name: json['Name'] as String? ?? '',
        driver: json['Driver'] as String? ?? '',
        scope: json['Scope'] as String? ?? '',
      );
}

class IpamConfig {
  final String? subnet;
  final String? gateway;
  final String? ipRange;
  const IpamConfig({this.subnet, this.gateway, this.ipRange});

  factory IpamConfig.fromJson(Map<String, dynamic> json) => IpamConfig(
        subnet: json['Subnet'] as String?,
        gateway: json['Gateway'] as String?,
        ipRange: json['IPRange'] as String?,
      );
}

class NetworkContainer {
  final String name;
  final String ipv4;
  const NetworkContainer({required this.name, required this.ipv4});
}

class NetworkDetail {
  final String id;
  final String name;
  final String driver;
  final String scope;
  final bool internal;
  final bool attachable;
  final bool enableIPv6;
  final String ipamDriver;
  final List<IpamConfig> ipam;
  final List<NetworkContainer> containers;
  final Map<String, String> labels;
  final Map<String, String> options;

  const NetworkDetail({
    required this.id,
    required this.name,
    required this.driver,
    required this.scope,
    required this.internal,
    required this.attachable,
    required this.enableIPv6,
    required this.ipamDriver,
    required this.ipam,
    required this.containers,
    required this.labels,
    required this.options,
  });

  factory NetworkDetail.fromJson(Map<String, dynamic> json) {
    final ipamObj = (json['IPAM'] as Map<String, dynamic>?) ?? const {};
    final config = (ipamObj['Config'] as List?) ?? const [];
    final containersObj = (json['Containers'] as Map<String, dynamic>?) ?? const {};
    return NetworkDetail(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      driver: json['Driver'] as String? ?? '',
      scope: json['Scope'] as String? ?? '',
      internal: json['Internal'] as bool? ?? false,
      attachable: json['Attachable'] as bool? ?? false,
      enableIPv6: json['EnableIPv6'] as bool? ?? false,
      ipamDriver: ipamObj['Driver'] as String? ?? '',
      ipam: config.map((c) => IpamConfig.fromJson(c as Map<String, dynamic>)).toList(),
      containers: containersObj.entries
          .map((e) => NetworkContainer(
                name: (e.value as Map<String, dynamic>)['Name'] as String? ?? '',
                ipv4: (e.value as Map<String, dynamic>)['IPv4Address'] as String? ?? '',
              ))
          .toList(),
      labels: ((json['Labels'] as Map<String, dynamic>?) ?? const {}).map((k, v) => MapEntry(k, '$v')),
      options: ((json['Options'] as Map<String, dynamic>?) ?? const {}).map((k, v) => MapEntry(k, '$v')),
    );
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/docker_network_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/models/docker_network.dart app/test/api/models/docker_network_test.dart
git commit -m "feat(app): network models (DockerNetwork, IpamConfig, NetworkDetail)"
```

---

## Task 3: DockerApiClient — network methods

**Files:**
- Modify: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/docker_api_client_networks_test.dart`

**Interfaces:**
- Consumes: `Transport` (existing), network models (Task 2).
- Produces on `DockerApiClient`: `listNetworks()`, `inspectNetwork(id)`, `createNetwork({...})`, `removeNetwork(id)`, `pruneNetworks()`.

- [ ] **Step 1: Write the failing test**

Create `app/test/api/docker_api_client_networks_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/api/models/docker_network.dart';

class _FakeTransport implements Transport {
  Object? lastPostBody;
  String? lastPostPath;
  final List<String> deletes = [];
  http.Response getResponse = http.Response('[]', 200);
  int postStatus = 201;
  int deleteStatus = 204;

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => getResponse;
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    lastPostPath = path;
    lastPostBody = body;
    return http.Response('{"Id":"n9"}', postStatus);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    deletes.add(path);
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
  test('listNetworks parses the array', () async {
    final t = _FakeTransport()
      ..getResponse = http.Response('[{"Id":"n1","Name":"bridge","Driver":"bridge","Scope":"local"}]', 200);
    final nets = await DockerApiClient(t).listNetworks();
    expect(nets.single.name, 'bridge');
  });

  test('createNetwork builds the rich body and returns the Id', () async {
    final t = _FakeTransport();
    final id = await DockerApiClient(t).createNetwork(
      name: 'mynet',
      driver: 'bridge',
      internal: true,
      ipam: const [IpamConfig(subnet: '10.0.0.0/24', gateway: '10.0.0.1')],
      labels: const {'env': 'prod'},
    );

    expect(id, 'n9');
    expect(t.lastPostPath, '/networks/create');
    final body = t.lastPostBody as Map<String, dynamic>;
    expect(body['Name'], 'mynet');
    expect(body['Driver'], 'bridge');
    expect(body['Internal'], true);
    expect(body['IPAM']['Config'], [
      {'Subnet': '10.0.0.0/24', 'Gateway': '10.0.0.1'}
    ]);
    expect(body['Labels'], {'env': 'prod'});
    expect(body.containsKey('Options'), isFalse); // empty options omitted
  });

  test('createNetwork omits IPAM when there are no configs', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).createNetwork(name: 'n');
    final body = t.lastPostBody as Map<String, dynamic>;
    expect(body.containsKey('IPAM'), isFalse);
  });

  test('removeNetwork deletes (204) and a 403 throws', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).removeNetwork('n1');
    expect(t.deletes, contains('/networks/n1'));

    final t2 = _FakeTransport()..deleteStatus = 403;
    expect(() => DockerApiClient(t2).removeNetwork('bridge'), throwsA(isA<DockerApiException>()));
  });

  test('pruneNetworks posts to /networks/prune', () async {
    final t = _FakeTransport()..postStatus = 200;
    await DockerApiClient(t).pruneNetworks();
    expect(t.lastPostPath, '/networks/prune');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/docker_api_client_networks_test.dart`
Expected: FAIL — network methods undefined.

- [ ] **Step 3: Add the methods**

In `app/lib/src/api/docker_api_client.dart`, add `import 'models/docker_network.dart';`, then append inside `DockerApiClient`:
```dart
  Future<List<DockerNetwork>> listNetworks() async {
    final resp = await transport.get('/networks');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as List).map((e) => DockerNetwork.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<NetworkDetail> inspectNetwork(String id) async {
    final resp = await transport.get('/networks/$id');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return NetworkDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<String> createNetwork({
    required String name,
    String driver = 'bridge',
    bool internal = false,
    bool attachable = false,
    bool enableIPv6 = false,
    List<IpamConfig> ipam = const [],
    Map<String, String> labels = const {},
    Map<String, String> options = const {},
  }) async {
    final body = <String, dynamic>{
      'Name': name,
      'Driver': driver,
      'Internal': internal,
      'Attachable': attachable,
      'EnableIPv6': enableIPv6,
    };
    if (ipam.isNotEmpty) {
      body['IPAM'] = {
        'Driver': 'default',
        'Config': ipam.map((c) {
          final m = <String, dynamic>{};
          if (c.subnet != null && c.subnet!.isNotEmpty) m['Subnet'] = c.subnet;
          if (c.gateway != null && c.gateway!.isNotEmpty) m['Gateway'] = c.gateway;
          if (c.ipRange != null && c.ipRange!.isNotEmpty) m['IPRange'] = c.ipRange;
          return m;
        }).toList(),
      };
    }
    if (labels.isNotEmpty) body['Labels'] = labels;
    if (options.isNotEmpty) body['Options'] = options;

    final resp = await transport.post('/networks/create', body: body);
    if (resp.statusCode != 201) throw DockerApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as Map<String, dynamic>)['Id'] as String;
  }

  Future<void> removeNetwork(String id) async =>
      _ensure(await transport.delete('/networks/$id'), ok: const {204});

  Future<void> pruneNetworks() async =>
      _ensure(await transport.post('/networks/prune'), ok: const {200});
```

- [ ] **Step 4: Run the tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/ && flutter analyze`
Expected: PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/docker_api_client.dart app/test/api/docker_api_client_networks_test.dart
git commit -m "feat(app): DockerApiClient network methods (list/inspect/create/remove/prune)"
```

---

## Task 4: NetworkCreateSheet (rich form)

**Files:**
- Create: `app/lib/src/ui/network_create_sheet.dart`
- Test: `app/test/ui/network_create_sheet_test.dart`

**Interfaces:**
- Consumes: `createNetwork` (Task 3), `IpamConfig` (Task 2), `KeyValueEditor` (Task 1), `dockerClientProvider`, `networksProvider` (added in Task 6 — but referenced here; see note).
- Produces: `class NetworkCreateSheet extends ConsumerStatefulWidget { const NetworkCreateSheet({super.key}); }`.
- **Note:** this task references `networksProvider`; add that provider FIRST as part of this task's Step 3 (a 4-line addition) so this task compiles independently.

- [ ] **Step 1: Add networksProvider (needed for invalidation)**

In `app/lib/src/state/providers.dart`, add `import '../api/models/docker_network.dart';` and:
```dart
final networksProvider = FutureProvider<List<DockerNetwork>>((ref) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.listNetworks();
});
```

- [ ] **Step 2: Write the failing widget test**

Create `app/test/ui/network_create_sheet_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/network_create_sheet.dart';

class _FakeTransport implements Transport {
  Map<String, dynamic>? createBody;
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    if (path == '/networks/create') createBody = body as Map<String, dynamic>;
    return http.Response('{"Id":"n9"}', 201);
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
  testWidgets('fills the form and creates a network with subnet + label', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: NetworkCreateSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'mynet');

    // Add one IPAM subnet row.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add subnet'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Subnet (CIDR)'), '10.0.0.0/24');

    // Add one label via the Labels KeyValueEditor (first Add icon belongs to Labels).
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'key'), 'env');
    await tester.enterText(find.widgetWithText(TextField, 'value'), 'prod');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(t.createBody, isNotNull);
    expect(t.createBody!['Name'], 'mynet');
    expect(t.createBody!['IPAM']['Config'], [
      {'Subnet': '10.0.0.0/24'}
    ]);
    expect(t.createBody!['Labels'], {'env': 'prod'});
  });

  testWidgets('Create is disabled until a name is entered', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: NetworkCreateSheet()),
    ));
    await tester.pumpAndSettle();

    final btn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'));
    expect(btn.onPressed, isNull); // disabled
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/network_create_sheet_test.dart`
Expected: FAIL — `NetworkCreateSheet` undefined.

- [ ] **Step 4: Write NetworkCreateSheet**

Create `app/lib/src/ui/network_create_sheet.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/docker_network.dart';
import '../state/providers.dart';
import 'widgets/key_value_editor.dart';

class _SubnetRow {
  final TextEditingController subnet = TextEditingController();
  final TextEditingController gateway = TextEditingController();
  final TextEditingController ipRange = TextEditingController();
  void dispose() {
    subnet.dispose();
    gateway.dispose();
    ipRange.dispose();
  }
}

class NetworkCreateSheet extends ConsumerStatefulWidget {
  const NetworkCreateSheet({super.key});

  @override
  ConsumerState<NetworkCreateSheet> createState() => _NetworkCreateSheetState();
}

class _NetworkCreateSheetState extends ConsumerState<NetworkCreateSheet> {
  final _name = TextEditingController();
  String _driver = 'bridge';
  bool _internal = false;
  bool _attachable = false;
  bool _enableIPv6 = false;
  final List<_SubnetRow> _subnets = [];
  Map<String, String> _labels = {};
  Map<String, String> _options = {};
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _name.addListener(() => setState(() {})); // toggle Create enabled
  }

  @override
  void dispose() {
    _name.dispose();
    for (final s in _subnets) {
      s.dispose();
    }
    super.dispose();
  }

  Future<void> _create() async {
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _busy = true);
    try {
      await client.createNetwork(
        name: _name.text.trim(),
        driver: _driver,
        internal: _internal,
        attachable: _attachable,
        enableIPv6: _enableIPv6,
        ipam: _subnets
            .map((s) => IpamConfig(subnet: s.subnet.text.trim(), gateway: s.gateway.text.trim(), ipRange: s.ipRange.text.trim()))
            .where((c) => (c.subnet ?? '').isNotEmpty || (c.gateway ?? '').isNotEmpty || (c.ipRange ?? '').isNotEmpty)
            .toList(),
        labels: _labels,
        options: _options,
      );
      ref.invalidate(networksProvider);
      navigator.pop();
      messenger.showSnackBar(const SnackBar(content: Text('Network created')));
    } catch (e) {
      setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = !_busy && _name.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: const Text('Create network')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
          const SizedBox(height: 8),
          Row(children: [
            const Text('Driver'),
            const SizedBox(width: 12),
            DropdownButton<String>(
              value: _driver,
              items: const ['bridge', 'overlay', 'macvlan', 'ipvlan']
                  .map((d) => DropdownMenuItem(value: d, child: Text(d)))
                  .toList(),
              onChanged: (v) => setState(() => _driver = v ?? 'bridge'),
            ),
          ]),
          SwitchListTile(title: const Text('Internal'), value: _internal, onChanged: (v) => setState(() => _internal = v)),
          SwitchListTile(title: const Text('Attachable'), value: _attachable, onChanged: (v) => setState(() => _attachable = v)),
          SwitchListTile(title: const Text('Enable IPv6'), value: _enableIPv6, onChanged: (v) => setState(() => _enableIPv6 = v)),
          const Divider(),
          Row(children: [
            const Text('IPAM subnets', style: TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            OutlinedButton(onPressed: () => setState(() => _subnets.add(_SubnetRow())), child: const Text('Add subnet')),
          ]),
          for (var i = 0; i < _subnets.length; i++)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Column(children: [
                  TextField(controller: _subnets[i].subnet, decoration: const InputDecoration(labelText: 'Subnet (CIDR)')),
                  TextField(controller: _subnets[i].gateway, decoration: const InputDecoration(labelText: 'Gateway')),
                  TextField(controller: _subnets[i].ipRange, decoration: const InputDecoration(labelText: 'IP range')),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton(
                      onPressed: () => setState(() => _subnets.removeAt(i).dispose()),
                      child: const Text('Remove subnet'),
                    ),
                  ),
                ]),
              ),
            ),
          const Divider(),
          KeyValueEditor(title: 'Labels', onChanged: (m) => _labels = m),
          const Divider(),
          KeyValueEditor(title: 'Options', onChanged: (m) => _options = m),
          const SizedBox(height: 16),
          FilledButton(onPressed: canCreate ? _create : null, child: const Text('Create')),
        ],
      ),
    );
  }
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/network_create_sheet_test.dart`
Expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/state/providers.dart app/lib/src/ui/network_create_sheet.dart app/test/ui/network_create_sheet_test.dart
git commit -m "feat(app): NetworkCreateSheet (rich create: driver/IPAM/labels/options)"
```

---

## Task 5: NetworkDetailScreen + networkDetailProvider

**Files:**
- Modify: `app/lib/src/state/providers.dart`
- Create: `app/lib/src/ui/network_detail_screen.dart`
- Test: `app/test/ui/network_detail_screen_test.dart`

**Interfaces:**
- Consumes: `inspectNetwork`/`removeNetwork` (Task 3), `NetworkDetail` (Task 2), `networksProvider` (Task 4), `dockerClientProvider`.
- Produces: `networkDetailProvider`; `class NetworkDetailScreen extends ConsumerWidget { const NetworkDetailScreen({required this.networkId, required this.title}); }`.

- [ ] **Step 1: Add the provider**

In `app/lib/src/state/providers.dart`, add:
```dart
final networkDetailProvider = FutureProvider.family<NetworkDetail, String>((ref, id) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.inspectNetwork(id);
});
```

- [ ] **Step 2: Write the failing widget test**

Create `app/test/ui/network_detail_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/network_detail_screen.dart';

class _FakeTransport implements Transport {
  final List<String> deletes = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response(
        '{"Id":"n1","Name":"mynet","Driver":"bridge","Scope":"local","Internal":true,"IPAM":{"Driver":"default","Config":[{"Subnet":"10.0.0.0/24","Gateway":"10.0.0.1"}]},"Containers":{"abc":{"Name":"web","IPv4Address":"10.0.0.2/24"}},"Labels":{"env":"prod"}}',
        200,
      );
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('', 200);
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
                builder: (_) => const NetworkDetailScreen(networkId: 'n1', title: 'mynet'))),
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
  testWidgets('renders detail + connected containers and removes', (tester) async {
    final t = _FakeTransport();
    await _open(tester, t);

    expect(find.text('mynet'), findsOneWidget); // app bar title
    expect(find.textContaining('10.0.0.0/24'), findsWidgets); // subnet
    expect(find.textContaining('web'), findsWidgets); // connected container

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove')); // confirm
    await tester.pumpAndSettle();

    expect(t.deletes, contains('/networks/n1'));
    expect(find.text('open'), findsOneWidget); // popped back
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/network_detail_screen_test.dart`
Expected: FAIL — `NetworkDetailScreen` undefined.

- [ ] **Step 4: Write NetworkDetailScreen**

Create `app/lib/src/ui/network_detail_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

class NetworkDetailScreen extends ConsumerWidget {
  final String networkId;
  final String title;
  const NetworkDetailScreen({super.key, required this.networkId, required this.title});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(networkDetailProvider(networkId));
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) {
          final client = ref.read(dockerClientProvider);
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text('${d.driver} · ${d.scope}'),
              Text('Internal: ${d.internal}  ·  Attachable: ${d.attachable}  ·  IPv6: ${d.enableIPv6}'),
              const Divider(),
              const Text('IPAM', style: TextStyle(fontWeight: FontWeight.bold)),
              for (final c in d.ipam) Text('${c.subnet ?? '-'}  gw ${c.gateway ?? '-'}${c.ipRange != null ? '  range ${c.ipRange}' : ''}'),
              const Divider(),
              const Text('Connected containers', style: TextStyle(fontWeight: FontWeight.bold)),
              if (d.containers.isEmpty) const Text('none')
              else for (final c in d.containers) Text('${c.name}  ${c.ipv4}'),
              if (d.labels.isNotEmpty) ...[
                const Divider(),
                const Text('Labels', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final e in d.labels.entries) Text('${e.key} = ${e.value}'),
              ],
              if (d.options.isNotEmpty) ...[
                const Divider(),
                const Text('Options', style: TextStyle(fontWeight: FontWeight.bold)),
                for (final e in d.options.entries) Text('${e.key} = ${e.value}'),
              ],
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () async {
                  final messenger = ScaffoldMessenger.of(context);
                  final navigator = Navigator.of(context);
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (ctx) => AlertDialog(
                      title: const Text('Remove network?'),
                      content: Text('Remove "$title"?'),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove')),
                      ],
                    ),
                  );
                  if (ok != true || client == null) return;
                  try {
                    await client.removeNetwork(networkId);
                    ref.invalidate(networksProvider);
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/network_detail_screen_test.dart`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/state/providers.dart app/lib/src/ui/network_detail_screen.dart app/test/ui/network_detail_screen_test.dart
git commit -m "feat(app): NetworkDetailScreen (IPAM + connected containers + remove)"
```

---

## Task 6: NetworksScreen + HomeScreen Networks tab

**Files:**
- Create: `app/lib/src/ui/networks_screen.dart`
- Modify: `app/lib/src/ui/home_screen.dart`
- Test: `app/test/ui/networks_screen_test.dart`
- Modify: `app/test/ui/home_screen_test.dart`

**Interfaces:**
- Consumes: `networksProvider` (Task 4), `pruneNetworks` (Task 3), `NetworkCreateSheet` (Task 4), `NetworkDetailScreen` (Task 5).
- Produces: `class NetworksScreen extends ConsumerWidget`; `HomeScreen` gains a Networks tab.

- [ ] **Step 1: Write the failing tests**

Create `app/test/ui/networks_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/networks_screen.dart';

class _FakeTransport implements Transport {
  final List<String> posts = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async =>
      http.Response('[{"Id":"n1","Name":"mynet","Driver":"bridge","Scope":"local"}]', 200);
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
  testWidgets('lists networks and confirms Prune', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: NetworksScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('mynet'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.cleaning_services));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Prune'));
    await tester.pumpAndSettle();
    expect(t.posts, contains('/networks/prune'));
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/networks_screen_test.dart`
Expected: FAIL — `NetworksScreen` undefined.

- [ ] **Step 3: Write NetworksScreen**

Create `app/lib/src/ui/networks_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import 'network_create_sheet.dart';
import 'network_detail_screen.dart';

class NetworksScreen extends ConsumerWidget {
  const NetworksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final networks = ref.watch(networksProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Networks'),
        actions: [
          IconButton(
            tooltip: 'Create',
            icon: const Icon(Icons.add),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const NetworkCreateSheet())),
          ),
          IconButton(tooltip: 'Prune', icon: const Icon(Icons.cleaning_services), onPressed: () => _prune(context, ref)),
          IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(networksProvider)),
        ],
      ),
      body: networks.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => ListView.builder(
          itemCount: list.length,
          itemBuilder: (context, i) {
            final n = list[i];
            return ListTile(
              leading: const Icon(Icons.hub),
              title: Text(n.name),
              subtitle: Text('${n.driver} · ${n.scope}'),
              onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => NetworkDetailScreen(networkId: n.id, title: n.name))),
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
        title: const Text('Prune networks'),
        content: const Text('Remove all unused networks?'),
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
      await client.pruneNetworks();
      ref.invalidate(networksProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Pruned')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }
}
```

- [ ] **Step 4: Add the Networks tab to HomeScreen**

In `app/lib/src/ui/home_screen.dart`, add `import 'networks_screen.dart';`, add `NetworksScreen()` to the `IndexedStack` children, and add a third `NavigationDestination`:
```dart
      body: IndexedStack(
        index: _index,
        children: const [ContainersScreen(), ImagesScreen(), NetworksScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inventory), label: 'Containers'),
          NavigationDestination(icon: Icon(Icons.layers), label: 'Images'),
          NavigationDestination(icon: Icon(Icons.hub), label: 'Networks'),
        ],
      ),
```

- [ ] **Step 5: Extend the HomeScreen test for the Networks tab**

In `app/test/ui/home_screen_test.dart`, add to the existing `testWidgets` body (after the Images assertions, before the Containers re-select), or as a new assertion block:
```dart
    await tester.tap(find.byIcon(Icons.hub)); // Networks destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 2);
```
(Insert this right after the `expect(bar().selectedIndex, 1);` line; keep the final Containers re-select assertion.)

- [ ] **Step 6: Run analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; **all** app tests pass.

- [ ] **Step 7: Commit**

```bash
git add app/lib/src/ui/networks_screen.dart app/lib/src/ui/home_screen.dart app/test/ui/networks_screen_test.dart app/test/ui/home_screen_test.dart
git commit -m "feat(app): NetworksScreen + Networks bottom-nav tab"
```

---

## Self-Review

**1. Spec coverage:**
- `KeyValueEditor` (owns/disposes controllers) → Task 1. ✓
- Network models (DockerNetwork, IpamConfig, NetworkContainer, NetworkDetail) → Task 2. ✓
- Client list/inspect/create(rich body)/remove/prune + status codes → Task 3. ✓
- `NetworkCreateSheet` (driver/flags/IPAM/labels/options, name-validated) + `networksProvider` → Task 4. ✓
- `NetworkDetailScreen` (IPAM/containers/labels/options + remove confirm) + `networkDetailProvider` → Task 5. ✓
- `NetworksScreen` (list/create/prune/refresh/tap) + Networks tab → Task 6. ✓
- Error handling (403/409 via snackbars, name validation, controller disposal) → Tasks 3/4/5/6. ✓
- Out of scope (volumes, connect/disconnect, network update) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code step is complete. The IPAM omission rule is concrete code.

**3. Type consistency:** `KeyValueEditor({title, onChanged})` (Task 1) used in Task 4. Models (Task 2) used by Task 3/4/5. `createNetwork({name, driver, internal, attachable, enableIPv6, ipam, labels, options})` (Task 3) called from Task 4; `removeNetwork(id)`/`pruneNetworks()` from Tasks 5/6. `networksProvider` (Task 4) + `networkDetailProvider` (Task 5) watched by their screens. `NetworkCreateSheet()`/`NetworkDetailScreen(networkId,title)`/`NetworksScreen()` constructors match call sites. `IpamConfig({subnet,gateway,ipRange})` consistent across Tasks 2/3/4. ✓
