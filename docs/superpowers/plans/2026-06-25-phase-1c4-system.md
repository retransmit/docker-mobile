# Phase 1C-4 — System Dashboard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A System dashboard tab — daemon info/version, disk-usage breakdown, and a `docker system prune`-style action orchestrated client-side.

**Architecture:** App-only, using existing `Transport` methods. Add system models, `DockerApiClient` dashboard reads + the two new prunes + a `systemPrune` orchestrator, a combined dashboard provider, the `SystemScreen`, and a System bottom-nav tab.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `http` (all existing).

## Global Constraints

- **App-only slice:** no agent changes; NO new `Transport` methods (use existing get/post). All calls go through `DockerApiClient`.
- **Status codes:** all reads (`/info`, `/version`, `/system/df`) = `200`; `pruneContainers`/`pruneBuildCache` = `200`; non-success → `DockerApiException`.
- **System prune order:** `pruneContainers(); pruneNetworks(); pruneImages(danglingOnly: !allImages); pruneBuildCache(); if (includeVolumes) pruneVolumes();`.
- **Nav:** add a System `NavigationDestination` (icon `Icons.monitor_heart`); now Containers | Images | Networks | Volumes | System.
- **Provider:** one `systemDashboardProvider` fetching info+version+df in parallel.
- **Async + controller discipline:** capture `messenger` BEFORE any await; the prune confirm dialog uses `StatefulBuilder` (no controllers); `SystemScreen` is a `ConsumerWidget` (no `setState`).
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"`.
- **Discipline:** TDD, DRY, YAGNI, frequent commits, commit messages with NO `Co-Authored-By` trailer. Repo local/private on a feature branch.

---

## File Structure

```
app/lib/src/api/models/system_info.dart          # SystemInfo + VersionInfo + DiskUsage + DiskUsageCategory
app/lib/src/api/docker_api_client.dart            # + getInfo/getVersion/getDiskUsage/pruneContainers/pruneBuildCache/systemPrune
app/lib/src/state/providers.dart                  # + systemDashboardProvider
app/lib/src/ui/system_screen.dart                 # SystemScreen
app/lib/src/ui/home_screen.dart                   # + System tab
app/test/...                                        # mirrors the above
```

---

## Task 1: System models

**Files:**
- Create: `app/lib/src/api/models/system_info.dart`
- Test: `app/test/api/models/system_info_test.dart`

**Interfaces:**
- Produces:
  - `class SystemInfo { final String serverVersion, os, osType, architecture, kernelVersion, storageDriver; final int ncpu, memTotal, containers, containersRunning, containersPaused, containersStopped, images; factory SystemInfo.fromJson(Map); }`
  - `class VersionInfo { final String version, apiVersion, goVersion, os, arch; factory VersionInfo.fromJson(Map); }`
  - `class DiskUsageCategory { final String name; final int count, size; const DiskUsageCategory({required this.name, required this.count, required this.size}); }`
  - `class DiskUsage { final DiskUsageCategory images, containers, volumes, buildCache; int get total; factory DiskUsage.fromJson(Map); }`

- [ ] **Step 1: Write the failing test**

Create `app/test/api/models/system_info_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/system_info.dart';

void main() {
  test('SystemInfo parses /info', () {
    final i = SystemInfo.fromJson({
      'ServerVersion': '27.0.3',
      'OperatingSystem': 'Ubuntu 24.04',
      'OSType': 'linux',
      'Architecture': 'x86_64',
      'KernelVersion': '6.8.0',
      'NCPU': 8,
      'MemTotal': 16000000000,
      'Driver': 'overlay2',
      'Containers': 5,
      'ContainersRunning': 3,
      'ContainersPaused': 0,
      'ContainersStopped': 2,
      'Images': 12,
    });
    expect(i.serverVersion, '27.0.3');
    expect(i.osType, 'linux');
    expect(i.ncpu, 8);
    expect(i.storageDriver, 'overlay2');
    expect(i.containersRunning, 3);
    expect(i.images, 12);
  });

  test('VersionInfo parses /version', () {
    final v = VersionInfo.fromJson({'Version': '27.0.3', 'ApiVersion': '1.46', 'GoVersion': 'go1.22', 'Os': 'linux', 'Arch': 'amd64'});
    expect(v.version, '27.0.3');
    expect(v.apiVersion, '1.46');
    expect(v.arch, 'amd64');
  });

  test('DiskUsage sums the df arrays into per-category totals', () {
    final df = DiskUsage.fromJson({
      'Images': [{'Size': 100}, {'Size': 50}],
      'Containers': [{'SizeRw': 10}],
      'Volumes': [{'UsageData': {'Size': 7}}, {'UsageData': {'Size': 3}}],
      'BuildCache': [{'Size': 20}],
    });
    expect(df.images.count, 2);
    expect(df.images.size, 150);
    expect(df.containers.size, 10);
    expect(df.volumes.size, 10);
    expect(df.buildCache.size, 20);
    expect(df.total, 190);
  });

  test('DiskUsage tolerates missing arrays', () {
    final df = DiskUsage.fromJson({});
    expect(df.total, 0);
    expect(df.images.count, 0);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/system_info_test.dart`
Expected: FAIL — models undefined.

- [ ] **Step 3: Write the models**

Create `app/lib/src/api/models/system_info.dart`:
```dart
class SystemInfo {
  final String serverVersion;
  final String os;
  final String osType;
  final String architecture;
  final String kernelVersion;
  final String storageDriver;
  final int ncpu;
  final int memTotal;
  final int containers;
  final int containersRunning;
  final int containersPaused;
  final int containersStopped;
  final int images;

  const SystemInfo({
    required this.serverVersion,
    required this.os,
    required this.osType,
    required this.architecture,
    required this.kernelVersion,
    required this.storageDriver,
    required this.ncpu,
    required this.memTotal,
    required this.containers,
    required this.containersRunning,
    required this.containersPaused,
    required this.containersStopped,
    required this.images,
  });

  factory SystemInfo.fromJson(Map<String, dynamic> json) => SystemInfo(
        serverVersion: json['ServerVersion'] as String? ?? '',
        os: json['OperatingSystem'] as String? ?? '',
        osType: json['OSType'] as String? ?? '',
        architecture: json['Architecture'] as String? ?? '',
        kernelVersion: json['KernelVersion'] as String? ?? '',
        storageDriver: json['Driver'] as String? ?? '',
        ncpu: (json['NCPU'] as num?)?.toInt() ?? 0,
        memTotal: (json['MemTotal'] as num?)?.toInt() ?? 0,
        containers: (json['Containers'] as num?)?.toInt() ?? 0,
        containersRunning: (json['ContainersRunning'] as num?)?.toInt() ?? 0,
        containersPaused: (json['ContainersPaused'] as num?)?.toInt() ?? 0,
        containersStopped: (json['ContainersStopped'] as num?)?.toInt() ?? 0,
        images: (json['Images'] as num?)?.toInt() ?? 0,
      );
}

class VersionInfo {
  final String version;
  final String apiVersion;
  final String goVersion;
  final String os;
  final String arch;

  const VersionInfo({
    required this.version,
    required this.apiVersion,
    required this.goVersion,
    required this.os,
    required this.arch,
  });

  factory VersionInfo.fromJson(Map<String, dynamic> json) => VersionInfo(
        version: json['Version'] as String? ?? '',
        apiVersion: json['ApiVersion'] as String? ?? '',
        goVersion: json['GoVersion'] as String? ?? '',
        os: json['Os'] as String? ?? '',
        arch: json['Arch'] as String? ?? '',
      );
}

class DiskUsageCategory {
  final String name;
  final int count;
  final int size;
  const DiskUsageCategory({required this.name, required this.count, required this.size});
}

class DiskUsage {
  final DiskUsageCategory images;
  final DiskUsageCategory containers;
  final DiskUsageCategory volumes;
  final DiskUsageCategory buildCache;

  const DiskUsage({
    required this.images,
    required this.containers,
    required this.volumes,
    required this.buildCache,
  });

  int get total => images.size + containers.size + volumes.size + buildCache.size;

  factory DiskUsage.fromJson(Map<String, dynamic> json) {
    int sum(List? list, int Function(Map<String, dynamic>) f) =>
        (list ?? const []).fold(0, (s, e) => s + f(e as Map<String, dynamic>));
    final imgs = (json['Images'] as List?) ?? const [];
    final cons = (json['Containers'] as List?) ?? const [];
    final vols = (json['Volumes'] as List?) ?? const [];
    final cache = (json['BuildCache'] as List?) ?? const [];
    return DiskUsage(
      images: DiskUsageCategory(name: 'Images', count: imgs.length, size: sum(imgs, (m) => (m['Size'] as num?)?.toInt() ?? 0)),
      containers: DiskUsageCategory(name: 'Containers', count: cons.length, size: sum(cons, (m) => (m['SizeRw'] as num?)?.toInt() ?? 0)),
      volumes: DiskUsageCategory(name: 'Volumes', count: vols.length, size: sum(vols, (m) => ((m['UsageData'] as Map<String, dynamic>?)?['Size'] as num?)?.toInt() ?? 0)),
      buildCache: DiskUsageCategory(name: 'Build cache', count: cache.length, size: sum(cache, (m) => (m['Size'] as num?)?.toInt() ?? 0)),
    );
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/system_info_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/models/system_info.dart app/test/api/models/system_info_test.dart
git commit -m "feat(app): system models (SystemInfo, VersionInfo, DiskUsage)"
```

---

## Task 2: DockerApiClient — dashboard reads + system prune

**Files:**
- Modify: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/docker_api_client_system_test.dart`

**Interfaces:**
- Consumes: `Transport` (existing), system models (Task 1), existing `pruneNetworks`/`pruneImages`/`pruneVolumes`.
- Produces on `DockerApiClient`: `getInfo()`, `getVersion()`, `getDiskUsage()`, `pruneContainers()`, `pruneBuildCache()`, `systemPrune({allImages, includeVolumes})`.

- [ ] **Step 1: Write the failing test**

Create `app/test/api/docker_api_client_system_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _Rec {
  final String path;
  final Map<String, String>? query;
  _Rec(this.path, this.query);
}

class _FakeTransport implements Transport {
  final List<_Rec> posts = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path == '/info') return http.Response('{"ServerVersion":"27.0.3","NCPU":8,"Driver":"overlay2"}', 200);
    if (path == '/version') return http.Response('{"Version":"27.0.3","ApiVersion":"1.46"}', 200);
    if (path == '/system/df') return http.Response('{"Images":[{"Size":100}],"Containers":[],"Volumes":[],"BuildCache":[]}', 200);
    return http.Response('{}', 200);
  }
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(_Rec(path, query));
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
  test('getInfo/getVersion/getDiskUsage parse their endpoints', () async {
    final c = DockerApiClient(_FakeTransport());
    expect((await c.getInfo()).serverVersion, '27.0.3');
    expect((await c.getVersion()).apiVersion, '1.46');
    expect((await c.getDiskUsage()).images.size, 100);
  });

  test('pruneContainers/pruneBuildCache post to the right paths', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).pruneContainers();
    await DockerApiClient(t).pruneBuildCache();
    expect(t.posts.map((r) => r.path).toList(), ['/containers/prune', '/build/prune']);
  });

  test('systemPrune(all, volumes) runs the full sequence', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).systemPrune(allImages: true, includeVolumes: true);
    expect(t.posts.map((r) => r.path).toList(),
        ['/containers/prune', '/networks/prune', '/images/prune', '/build/prune', '/volumes/prune']);
    // images pruned with dangling:false (all)
    final imgCall = t.posts.firstWhere((r) => r.path == '/images/prune');
    expect(imgCall.query, {'filters': '{"dangling":["false"]}'});
  });

  test('systemPrune() defaults omit volumes and prune only dangling images', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).systemPrune();
    final paths = t.posts.map((r) => r.path).toList();
    expect(paths, ['/containers/prune', '/networks/prune', '/images/prune', '/build/prune']);
    expect(paths.contains('/volumes/prune'), isFalse);
    final imgCall = t.posts.firstWhere((r) => r.path == '/images/prune');
    expect(imgCall.query, {'filters': '{"dangling":["true"]}'});
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/docker_api_client_system_test.dart`
Expected: FAIL — system methods undefined.

- [ ] **Step 3: Add the methods**

In `app/lib/src/api/docker_api_client.dart`, add `import 'models/system_info.dart';`, then append inside `DockerApiClient`:
```dart
  Future<SystemInfo> getInfo() async {
    final resp = await transport.get('/info');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return SystemInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<VersionInfo> getVersion() async {
    final resp = await transport.get('/version');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return VersionInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<DiskUsage> getDiskUsage() async {
    final resp = await transport.get('/system/df');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return DiskUsage.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> pruneContainers() async =>
      _ensure(await transport.post('/containers/prune'), ok: const {200});

  Future<void> pruneBuildCache() async =>
      _ensure(await transport.post('/build/prune'), ok: const {200});

  Future<void> systemPrune({bool allImages = false, bool includeVolumes = false}) async {
    await pruneContainers();
    await pruneNetworks();
    await pruneImages(danglingOnly: !allImages);
    await pruneBuildCache();
    if (includeVolumes) await pruneVolumes();
  }
```

- [ ] **Step 4: Run the tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/ && flutter analyze`
Expected: PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/api/docker_api_client.dart app/test/api/docker_api_client_system_test.dart
git commit -m "feat(app): DockerApiClient system reads + systemPrune orchestrator"
```

---

## Task 3: systemDashboardProvider + SystemScreen + System tab

**Files:**
- Modify: `app/lib/src/state/providers.dart`
- Create: `app/lib/src/ui/system_screen.dart`
- Modify: `app/lib/src/ui/home_screen.dart`
- Test: `app/test/ui/system_screen_test.dart`
- Modify: `app/test/ui/home_screen_test.dart`

**Interfaces:**
- Consumes: `getInfo`/`getVersion`/`getDiskUsage`/`systemPrune` (Task 2), system models (Task 1), the resource list providers (existing).
- Produces: `systemDashboardProvider`; `class SystemScreen extends ConsumerWidget`; `HomeScreen` gains a System tab.

- [ ] **Step 1: Add the provider**

In `app/lib/src/state/providers.dart`, add `import '../api/models/system_info.dart';` and:
```dart
final systemDashboardProvider =
    FutureProvider<({SystemInfo info, VersionInfo version, DiskUsage df})>((ref) async {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  final infoF = client.getInfo();
  final versionF = client.getVersion();
  final dfF = client.getDiskUsage();
  return (info: await infoF, version: await versionF, df: await dfF);
});
```

- [ ] **Step 2: Write the failing widget test**

Create `app/test/ui/system_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/system_screen.dart';

class _FakeTransport implements Transport {
  final List<String> posts = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path == '/info') {
      return http.Response('{"ServerVersion":"27.0.3","OSType":"linux","Architecture":"x86_64","NCPU":8,"MemTotal":16000000000,"Driver":"overlay2","Containers":5,"ContainersRunning":3,"Images":12}', 200);
    }
    if (path == '/version') return http.Response('{"Version":"27.0.3","ApiVersion":"1.46","Arch":"amd64","Os":"linux"}', 200);
    if (path == '/system/df') return http.Response('{"Images":[{"Size":104857600}],"Containers":[],"Volumes":[],"BuildCache":[]}', 200);
    return http.Response('{}', 200);
  }
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
  testWidgets('renders daemon + disk usage', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: SystemScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.textContaining('27.0.3'), findsWidgets); // server version
    expect(find.textContaining('overlay2'), findsWidgets); // storage driver
    expect(find.textContaining('Images'), findsWidgets); // disk usage category
  });

  testWidgets('System prune with both toggles runs the full sequence', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: SystemScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'System prune'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // Toggle both switches on.
    await tester.tap(find.widgetWithText(SwitchListTile, 'All unused images'));
    await tester.tap(find.widgetWithText(SwitchListTile, 'Also unused volumes'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Prune'));
    await tester.pumpAndSettle();

    expect(t.posts, containsAll(<String>['/containers/prune', '/networks/prune', '/images/prune', '/build/prune', '/volumes/prune']));
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/system_screen_test.dart`
Expected: FAIL — `SystemScreen` undefined.

- [ ] **Step 4: Write SystemScreen**

Create `app/lib/src/ui/system_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/system_info.dart';
import '../state/providers.dart';

String _humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

class SystemScreen extends ConsumerWidget {
  const SystemScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final dash = ref.watch(systemDashboardProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('System'),
        actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: () => ref.invalidate(systemDashboardProvider))],
      ),
      body: dash.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (d) {
          final info = d.info;
          final v = d.version;
          final df = d.df;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _card('Daemon', [
                _kv('Version', info.serverVersion),
                _kv('API', v.apiVersion),
                _kv('OS / Arch', '${info.osType} / ${info.architecture}'),
                _kv('Kernel', info.kernelVersion),
                _kv('CPUs', '${info.ncpu}'),
                _kv('Memory', _humanSize(info.memTotal)),
                _kv('Storage driver', info.storageDriver),
              ]),
              _card('Containers', [
                _kv('Total', '${info.containers}'),
                _kv('Running', '${info.containersRunning}'),
                _kv('Paused', '${info.containersPaused}'),
                _kv('Stopped', '${info.containersStopped}'),
                _kv('Images', '${info.images}'),
              ]),
              _card('Disk usage', [
                for (final c in [df.images, df.containers, df.volumes, df.buildCache])
                  _kv('${c.name} (${c.count})', _humanSize(c.size)),
                _kv('Total', _humanSize(df.total)),
              ]),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                icon: const Icon(Icons.cleaning_services),
                label: const Text('System prune'),
                onPressed: () => _prune(context, ref),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _prune(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final opts = await _pruneDialog(context);
    if (opts == null) return;
    final client = ref.read(dockerClientProvider);
    if (client == null) return;
    try {
      await client.systemPrune(allImages: opts.$1, includeVolumes: opts.$2);
      ref.invalidate(systemDashboardProvider);
      ref.invalidate(containersProvider);
      ref.invalidate(imagesProvider);
      ref.invalidate(networksProvider);
      ref.invalidate(volumesProvider);
      messenger.showSnackBar(const SnackBar(content: Text('Pruned')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Failed: $e')));
    }
  }

  Widget _card(String title, List<Widget> rows) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              ...rows,
            ],
          ),
        ),
      );

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 130, child: Text(k)),
          Expanded(child: Text(v, style: const TextStyle(fontWeight: FontWeight.w500))),
        ]),
      );
}

/// Returns (allImages, includeVolumes), or null if cancelled.
Future<(bool, bool)?> _pruneDialog(BuildContext context) {
  var allImages = false;
  var includeVolumes = false;
  return showDialog<(bool, bool)>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        title: const Text('System prune'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Removes stopped containers, unused networks, dangling images, and build cache.'),
            SwitchListTile(title: const Text('All unused images'), value: allImages, onChanged: (val) => setState(() => allImages = val)),
            SwitchListTile(title: const Text('Also unused volumes'), value: includeVolumes, onChanged: (val) => setState(() => includeVolumes = val)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, (allImages, includeVolumes)), child: const Text('Prune')),
        ],
      ),
    ),
  );
}
```

- [ ] **Step 5: Run the widget test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/system_screen_test.dart`
Expected: PASS (both tests).

- [ ] **Step 6: Add the System tab to HomeScreen**

In `app/lib/src/ui/home_screen.dart`, add `import 'system_screen.dart';`, add `SystemScreen()` to the `IndexedStack` children, and add a fifth `NavigationDestination`:
```dart
      body: IndexedStack(
        index: _index,
        children: const [ContainersScreen(), ImagesScreen(), NetworksScreen(), VolumesScreen(), SystemScreen()],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.inventory), label: 'Containers'),
          NavigationDestination(icon: Icon(Icons.layers), label: 'Images'),
          NavigationDestination(icon: Icon(Icons.hub), label: 'Networks'),
          NavigationDestination(icon: Icon(Icons.storage), label: 'Volumes'),
          NavigationDestination(icon: Icon(Icons.monitor_heart), label: 'System'),
        ],
      ),
```

- [ ] **Step 7: Extend the HomeScreen test for the System tab**

In `app/test/ui/home_screen_test.dart`, add after the existing Volumes-tab assertion (`expect(bar().selectedIndex, 3);`):
```dart
    await tester.tap(find.byIcon(Icons.monitor_heart)); // System destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 4);
```
(Keep the final Containers re-select assertion last.)

- [ ] **Step 8: Run analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; **all** app tests pass.

- [ ] **Step 9: Commit**

```bash
git add app/lib/src/state/providers.dart app/lib/src/ui/system_screen.dart app/lib/src/ui/home_screen.dart app/test/ui/system_screen_test.dart app/test/ui/home_screen_test.dart
git commit -m "feat(app): SystemScreen dashboard + System bottom-nav tab"
```

---

## Self-Review

**1. Spec coverage:**
- Models (SystemInfo/VersionInfo/DiskUsage+Category, df summing) → Task 1. ✓
- Client getInfo/getVersion/getDiskUsage/pruneContainers/pruneBuildCache/systemPrune (order + dangling filter + optional volumes) → Task 2. ✓
- `systemDashboardProvider` (parallel) → Task 3. ✓
- `SystemScreen` (daemon/containers/disk cards + prune w/ two toggles + refresh) → Task 3. ✓
- System tab on `HomeScreen` (index 4) → Task 3. ✓
- Error handling (dashboard error state; prune snackbar; invalidates dashboard + resource lists) → Task 3. ✓
- Out of scope (daemon.json writes, events/stats, transports) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code step is complete. `_humanSize` is concrete.

**3. Type consistency:** `SystemInfo`/`VersionInfo`/`DiskUsage` (Task 1) used by Task 2/3. `systemPrune({allImages, includeVolumes})`/`pruneContainers()`/`pruneBuildCache()` (Task 2) called by Task 3. `systemDashboardProvider` returns `({SystemInfo info, VersionInfo version, DiskUsage df})` (Task 3 Step 1) consumed identically in `SystemScreen` (Task 3 Step 4). `_pruneDialog` returns `(bool, bool)?`. `SystemScreen()` constructor matches HomeScreen call site. ✓
