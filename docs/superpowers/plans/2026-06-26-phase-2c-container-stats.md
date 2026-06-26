# Phase 2C — Live Container Stats — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A live per-container stats screen — CPU%/memory% sparkline charts (fl_chart) + network/block-I/O numbers — streamed from the stats endpoint.

**Architecture:** A pure `ContainerStats` model computes metrics from each streamed stats object; `streamContainerStats` parses the NDJSON stream; a `StatsNotifier` (`StateNotifier`) keeps the latest sample + rolling windows behind an autoDispose family provider; `ContainerStatsScreen` renders fl_chart sparklines, reached via a Stats button on the container detail screen.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `fl_chart` (new).

## Global Constraints

- **App-only slice:** no agent changes; NO new `Transport` methods (use existing `stream`). All calls go through `DockerApiClient`.
- **Stream:** `GET /containers/{id}/stats?stream=true`, NDJSON byte-buffered (same pattern as `pullImage`); malformed lines skipped.
- **CPU% formula:** `(cpu_delta / system_delta) × online_cpus × 100`, guarded `system_delta > 0 && cpu_delta > 0` (each object carries `precpu_stats`).
- **Memory:** `used = (usage − cache).clamp(0, usage)`, cache = `stats.cache` ?? `stats.inactive_file` ?? 0; percent = `used/limit` (0 if limit ≤ 0).
- **`fromJson` tolerates** missing `cpu_stats`/`memory_stats`/`networks`/`blkio_stats` (→ 0); no throw.
- **Window:** `kStatsWindow = 60` rolling samples for the charts. Stream canceled on screen leave (autoDispose family provider).
- **Entry point:** a Stats `OutlinedButton.icon` on `ContainerDetailScreen` (next to Logs/Exec) → pushed `ContainerStatsScreen`.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/api/models/container_stats.dart       # ContainerStats + fromJson
app/lib/src/api/docker_api_client.dart            # + streamContainerStats
app/lib/src/state/stats_notifier.dart             # StatsState + StatsNotifier + statsProvider + kStatsWindow
app/lib/src/ui/container_stats_screen.dart        # ContainerStatsScreen (fl_chart)
app/lib/src/ui/container_detail_screen.dart       # + Stats button
app/pubspec.yaml                                   # + fl_chart
app/test/...                                        # mirrors the above
```

---

## Task 1: ContainerStats model + streamContainerStats

**Files:**
- Modify: `app/pubspec.yaml` (add `fl_chart`)
- Create: `app/lib/src/api/models/container_stats.dart`
- Modify: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/models/container_stats_test.dart`, `app/test/api/docker_api_client_stats_test.dart`

**Interfaces:**
- Produces:
  - `class ContainerStats { final double cpuPercent; final int memoryUsed, memoryLimit; final double memoryPercent; final int netRx, netTx, blockRead, blockWrite; const ContainerStats({...}); factory ContainerStats.fromJson(Map<String,dynamic>); }`
  - `DockerApiClient.streamContainerStats(String id) -> Stream<ContainerStats>`

- [ ] **Step 1: Add fl_chart**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter pub add fl_chart`
Expected: `pubspec.yaml` gains `fl_chart:`; `pub get` succeeds.

- [ ] **Step 2: Write the failing model test**

Create `app/test/api/models/container_stats_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container_stats.dart';

void main() {
  test('computes CPU%, memory, network, block I/O from a stats object', () {
    final s = ContainerStats.fromJson({
      'cpu_stats': {
        'cpu_usage': {'total_usage': 2000000000},
        'system_cpu_usage': 10000000000,
        'online_cpus': 4,
      },
      'precpu_stats': {
        'cpu_usage': {'total_usage': 1900000000},
        'system_cpu_usage': 9000000000,
      },
      'memory_stats': {
        'usage': 104857600,
        'limit': 1073741824,
        'stats': {'cache': 4857600},
      },
      'networks': {
        'eth0': {'rx_bytes': 1000, 'tx_bytes': 2000},
        'eth1': {'rx_bytes': 5, 'tx_bytes': 5},
      },
      'blkio_stats': {
        'io_service_bytes_recursive': [
          {'op': 'Read', 'value': 5000},
          {'op': 'Write', 'value': 3000},
        ],
      },
    });
    expect(s.cpuPercent, closeTo(40.0, 0.001)); // (1e8/1e9)*4*100
    expect(s.memoryUsed, 100000000); // 104857600 - 4857600
    expect(s.memoryLimit, 1073741824);
    expect(s.memoryPercent, closeTo(100000000 / 1073741824 * 100, 0.001));
    expect(s.netRx, 1005);
    expect(s.netTx, 2005);
    expect(s.blockRead, 5000);
    expect(s.blockWrite, 3000);
  });

  test('system_delta <= 0 -> 0% CPU; missing sections -> 0', () {
    final s = ContainerStats.fromJson({
      'cpu_stats': {'cpu_usage': {'total_usage': 100}, 'system_cpu_usage': 100, 'online_cpus': 2},
      'precpu_stats': {'cpu_usage': {'total_usage': 50}, 'system_cpu_usage': 100},
    });
    expect(s.cpuPercent, 0.0); // system_delta == 0
    expect(s.memoryUsed, 0);
    expect(s.memoryLimit, 0);
    expect(s.memoryPercent, 0.0);
    expect(s.netRx, 0);
    expect(s.blockRead, 0);
  });
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/container_stats_test.dart`
Expected: FAIL — `ContainerStats` undefined.

- [ ] **Step 4: Write the model**

Create `app/lib/src/api/models/container_stats.dart`:
```dart
class ContainerStats {
  final double cpuPercent;
  final int memoryUsed;
  final int memoryLimit;
  final double memoryPercent;
  final int netRx;
  final int netTx;
  final int blockRead;
  final int blockWrite;

  const ContainerStats({
    required this.cpuPercent,
    required this.memoryUsed,
    required this.memoryLimit,
    required this.memoryPercent,
    required this.netRx,
    required this.netTx,
    required this.blockRead,
    required this.blockWrite,
  });

  factory ContainerStats.fromJson(Map<String, dynamic> json) {
    final cpu = (json['cpu_stats'] as Map?) ?? const {};
    final pre = (json['precpu_stats'] as Map?) ?? const {};
    double num_(Map m, String k) => (m[k] as num?)?.toDouble() ?? 0;
    final cpuUsage = (cpu['cpu_usage'] as Map?) ?? const {};
    final preUsage = (pre['cpu_usage'] as Map?) ?? const {};
    final cpuDelta = num_(cpuUsage, 'total_usage') - num_(preUsage, 'total_usage');
    final sysDelta = num_(cpu, 'system_cpu_usage') - num_(pre, 'system_cpu_usage');
    final online = (cpu['online_cpus'] as num?)?.toDouble() ??
        ((cpuUsage['percpu_usage'] as List?)?.length.toDouble()) ??
        1.0;
    final cpuPercent = (sysDelta > 0 && cpuDelta > 0) ? (cpuDelta / sysDelta) * online * 100 : 0.0;

    final mem = (json['memory_stats'] as Map?) ?? const {};
    final usage = (mem['usage'] as num?)?.toInt() ?? 0;
    final memStats = (mem['stats'] as Map?) ?? const {};
    final cache = (memStats['cache'] as num?)?.toInt() ?? (memStats['inactive_file'] as num?)?.toInt() ?? 0;
    final used = (usage - cache).clamp(0, usage);
    final limit = (mem['limit'] as num?)?.toInt() ?? 0;
    final memPercent = limit > 0 ? used / limit * 100 : 0.0;

    var rx = 0, tx = 0;
    final nets = (json['networks'] as Map?) ?? const {};
    for (final v in nets.values) {
      final m = (v as Map?) ?? const {};
      rx += (m['rx_bytes'] as num?)?.toInt() ?? 0;
      tx += (m['tx_bytes'] as num?)?.toInt() ?? 0;
    }

    var read = 0, write = 0;
    final blk = ((json['blkio_stats'] as Map?)?['io_service_bytes_recursive'] as List?) ?? const [];
    for (final e in blk) {
      final m = (e as Map?) ?? const {};
      final op = (m['op'] as String?)?.toLowerCase();
      final value = (m['value'] as num?)?.toInt() ?? 0;
      if (op == 'read') read += value;
      if (op == 'write') write += value;
    }

    return ContainerStats(
      cpuPercent: cpuPercent,
      memoryUsed: used,
      memoryLimit: limit,
      memoryPercent: memPercent,
      netRx: rx,
      netTx: tx,
      blockRead: read,
      blockWrite: write,
    );
  }
}
```

- [ ] **Step 5: Run the model test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/container_stats_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Write the failing client test**

Create `app/test/api/docker_api_client_stats_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _FakeTransport implements Transport {
  String? lastStreamPath;
  Map<String, String>? lastStreamQuery;
  final List<List<int>> chunks;
  _FakeTransport(this.chunks);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    lastStreamPath = path;
    lastStreamQuery = query;
    return Stream.fromIterable(chunks);
  }
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{}', 200);
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async => http.Response('', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
  @override
  Future<void> close() async {}
}

String _statsLine(int total) =>
    '{"cpu_stats":{"cpu_usage":{"total_usage":$total},"system_cpu_usage":2000000000,"online_cpus":1},'
    '"precpu_stats":{"cpu_usage":{"total_usage":0},"system_cpu_usage":1000000000},'
    '"memory_stats":{"usage":50,"limit":100}}';

void main() {
  test('streamContainerStats requests the stream and parses NDJSON across chunks', () async {
    final l1 = _statsLine(100000000);
    final l2 = _statsLine(200000000);
    // Split the NDJSON mid-first-line across two chunks.
    final all = '$l1\n$l2\n';
    final cut = l1.length - 3;
    final t = _FakeTransport([utf8.encode(all.substring(0, cut)), utf8.encode(all.substring(cut))]);
    final stats = await DockerApiClient(t).streamContainerStats('abc').toList();

    expect(t.lastStreamPath, '/containers/abc/stats');
    expect(t.lastStreamQuery, {'stream': 'true'});
    expect(stats.length, 2);
    expect(stats[0].memoryUsed, 50);
  });

  test('skips a malformed NDJSON line', () async {
    final t = _FakeTransport([utf8.encode('not json\n${_statsLine(1)}\n')]);
    final stats = await DockerApiClient(t).streamContainerStats('abc').toList();
    expect(stats.length, 1);
  });
}
```

- [ ] **Step 7: Add `streamContainerStats`**

In `app/lib/src/api/docker_api_client.dart`, add `import 'models/container_stats.dart';` and append inside `DockerApiClient`:
```dart
  Stream<ContainerStats> streamContainerStats(String id) async* {
    final raw = transport.stream('/containers/$id/stats', query: {'stream': 'true'});
    final buffer = <int>[];
    await for (final chunk in raw) {
      buffer.addAll(chunk);
      var nl = buffer.indexOf(0x0A);
      while (nl != -1) {
        final line = utf8.decode(buffer.sublist(0, nl), allowMalformed: true).trim();
        buffer.removeRange(0, nl + 1);
        if (line.isNotEmpty) {
          try {
            yield ContainerStats.fromJson(jsonDecode(line) as Map<String, dynamic>);
          } catch (_) {
            // skip a malformed/partial line
          }
        }
        nl = buffer.indexOf(0x0A);
      }
    }
  }
```

- [ ] **Step 8: Run both tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/container_stats_test.dart test/api/docker_api_client_stats_test.dart && flutter analyze`
Expected: PASS (4 tests); analyzer clean.

- [ ] **Step 9: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/src/api/models/container_stats.dart app/lib/src/api/docker_api_client.dart app/test/api/models/container_stats_test.dart app/test/api/docker_api_client_stats_test.dart
git commit -m "feat(app): ContainerStats model + streamContainerStats (+ fl_chart dep)"
```

---

## Task 2: StatsNotifier + provider

**Files:**
- Create: `app/lib/src/state/stats_notifier.dart`
- Test: `app/test/state/stats_notifier_test.dart`

**Interfaces:**
- Consumes: `ContainerStats`/`streamContainerStats` (Task 1), `dockerClientProvider` (providers.dart).
- Produces: `const int kStatsWindow`; `enum StatsStatus { loading, streaming, error }`; `class StatsState { ContainerStats? latest; List<double> cpuHistory, memHistory; StatsStatus status; String? error; }`; `class StatsNotifier extends StateNotifier<StatsState> { StatsNotifier(DockerApiClient, String id); }`; `statsProvider` (autoDispose family).

- [ ] **Step 1: Write the failing test**

Create `app/test/state/stats_notifier_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/stats_notifier.dart';

class _FakeTransport implements Transport {
  final Stream<List<int>> Function() build;
  _FakeTransport(this.build);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => build();
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{}', 200);
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async => http.Response('', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
  @override
  Future<void> close() async {}
}

String _line(int total) =>
    '{"cpu_stats":{"cpu_usage":{"total_usage":$total},"system_cpu_usage":2000000000,"online_cpus":1},'
    '"precpu_stats":{"cpu_usage":{"total_usage":0},"system_cpu_usage":1000000000},'
    '"memory_stats":{"usage":50,"limit":100}}';

void main() {
  test('samples update latest and grow the rolling windows (capped)', () async {
    final lines = [for (var i = 0; i < kStatsWindow + 5; i++) _line((i + 1) * 1000000)].join('\n') + '\n';
    final client = DockerApiClient(_FakeTransport(() => Stream.value(utf8.encode(lines))));
    final n = StatsNotifier(client, 'a');
    await pumpEventQueue();
    expect(n.state.status, StatsStatus.streaming);
    expect(n.state.latest, isNotNull);
    expect(n.state.cpuHistory.length, kStatsWindow); // capped
    expect(n.state.memHistory.length, kStatsWindow);
    n.dispose();
  });

  test('a stream error sets error status', () async {
    final client = DockerApiClient(_FakeTransport(() => Stream.error(Exception('boom'))));
    final n = StatsNotifier(client, 'a');
    await pumpEventQueue();
    expect(n.state.status, StatsStatus.error);
    expect(n.state.error, contains('boom'));
    n.dispose();
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/state/stats_notifier_test.dart`
Expected: FAIL — `StatsNotifier` undefined.

- [ ] **Step 3: Write the notifier + provider**

Create `app/lib/src/state/stats_notifier.dart`:
```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_stats.dart';
import 'providers.dart';

const int kStatsWindow = 60;

enum StatsStatus { loading, streaming, error }

class StatsState {
  final ContainerStats? latest;
  final List<double> cpuHistory;
  final List<double> memHistory;
  final StatsStatus status;
  final String? error;

  const StatsState({
    this.latest,
    this.cpuHistory = const [],
    this.memHistory = const [],
    this.status = StatsStatus.loading,
    this.error,
  });

  StatsState copyWith({
    ContainerStats? latest,
    List<double>? cpuHistory,
    List<double>? memHistory,
    StatsStatus? status,
    String? error,
  }) =>
      StatsState(
        latest: latest ?? this.latest,
        cpuHistory: cpuHistory ?? this.cpuHistory,
        memHistory: memHistory ?? this.memHistory,
        status: status ?? this.status,
        error: error ?? this.error,
      );
}

class StatsNotifier extends StateNotifier<StatsState> {
  StreamSubscription<ContainerStats>? _sub;

  StatsNotifier(DockerApiClient client, String id) : super(const StatsState()) {
    _sub = client.streamContainerStats(id).listen(
      (s) {
        final cpu = [...state.cpuHistory, s.cpuPercent];
        final mem = [...state.memHistory, s.memoryPercent];
        state = state.copyWith(
          latest: s,
          cpuHistory: cpu.length > kStatsWindow ? cpu.sublist(cpu.length - kStatsWindow) : cpu,
          memHistory: mem.length > kStatsWindow ? mem.sublist(mem.length - kStatsWindow) : mem,
          status: StatsStatus.streaming,
        );
      },
      onError: (Object e) => state = state.copyWith(status: StatsStatus.error, error: '$e'),
      cancelOnError: true,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// Live stats for a container; auto-disposes (and cancels the stream) when the
/// screen that watches it leaves.
final statsProvider = StateNotifierProvider.autoDispose.family<StatsNotifier, StatsState, String>((ref, id) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return StatsNotifier(client, id);
});
```

- [ ] **Step 4: Run the test + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/state/stats_notifier_test.dart && flutter analyze`
Expected: PASS (2 tests); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/state/stats_notifier.dart app/test/state/stats_notifier_test.dart
git commit -m "feat(app): StatsNotifier + statsProvider (rolling CPU/mem windows)"
```

---

## Task 3: ContainerStatsScreen + Stats button

**Files:**
- Create: `app/lib/src/ui/container_stats_screen.dart`
- Modify: `app/lib/src/ui/container_detail_screen.dart`
- Test: `app/test/ui/container_stats_screen_test.dart`

**Interfaces:**
- Consumes: `statsProvider`/`StatsStatus`/`StatsState` (Task 2), `transportProvider`/`dockerClientProvider` (providers.dart), `ContainerStats` (Task 1), `fl_chart`.
- Produces: `class ContainerStatsScreen extends ConsumerWidget { ContainerStatsScreen({required String containerId, required String containerName}); }`; a Stats button on `ContainerDetailScreen`.

- [ ] **Step 1: Write the failing test**

Create `app/test/ui/container_stats_screen_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/container_stats_screen.dart';

class _FakeTransport implements Transport {
  final List<int>? statsBytes;
  _FakeTransport({this.statsBytes});
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) =>
      statsBytes == null ? const Stream.empty() : Stream.value(statsBytes!);
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{}', 200);
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async => http.Response('', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
  @override
  Future<void> close() async {}
}

const _sample =
    '{"cpu_stats":{"cpu_usage":{"total_usage":2000000000},"system_cpu_usage":10000000000,"online_cpus":4},'
    '"precpu_stats":{"cpu_usage":{"total_usage":1900000000},"system_cpu_usage":9000000000},'
    '"memory_stats":{"usage":104857600,"limit":1073741824,"stats":{"cache":4857600}},'
    '"networks":{"eth0":{"rx_bytes":1024,"tx_bytes":2048}},'
    '"blkio_stats":{"io_service_bytes_recursive":[{"op":"Read","value":4096},{"op":"Write","value":8192}]}}';

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ContainerStatsScreen(containerId: 'abc', containerName: 'web')),
    );

void main() {
  testWidgets('shows a waiting state before the first sample', (tester) async {
    await tester.pumpWidget(_wrap(_FakeTransport()));
    await tester.pump();
    expect(find.textContaining('Waiting'), findsOneWidget);
  });

  testWidgets('renders CPU%, memory and I/O from a sample', (tester) async {
    await tester.pumpWidget(_wrap(_FakeTransport(statsBytes: utf8.encode('$_sample\n'))));
    await tester.pumpAndSettle();
    expect(find.textContaining('40.0'), findsWidgets); // CPU %
    expect(find.textContaining('CPU'), findsWidgets);
    expect(find.textContaining('Memory'), findsWidgets);
    expect(find.textContaining('Network'), findsWidgets);
    expect(find.textContaining('Block'), findsWidgets);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/container_stats_screen_test.dart`
Expected: FAIL — `ContainerStatsScreen` undefined.

- [ ] **Step 3: Write the screen**

Create `app/lib/src/ui/container_stats_screen.dart`:
```dart
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/stats_notifier.dart';

String _humanBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

class ContainerStatsScreen extends ConsumerWidget {
  final String containerId;
  final String containerName;
  const ContainerStatsScreen({super.key, required this.containerId, required this.containerName});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(statsProvider(containerId));
    return Scaffold(
      appBar: AppBar(title: Text('Stats · $containerName')),
      body: _body(s),
    );
  }

  Widget _body(StatsState s) {
    if (s.status == StatsStatus.error) return Center(child: Text('Error: ${s.error}'));
    final latest = s.latest;
    if (latest == null) return const Center(child: Text('Waiting for stats…'));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _chartCard('CPU', '${latest.cpuPercent.toStringAsFixed(1)} %', s.cpuHistory),
        const SizedBox(height: 12),
        _chartCard(
          'Memory',
          '${_humanBytes(latest.memoryUsed)} / ${_humanBytes(latest.memoryLimit)}  (${latest.memoryPercent.toStringAsFixed(1)} %)',
          s.memHistory,
        ),
        const SizedBox(height: 12),
        _numberCard('Network', 'RX ${_humanBytes(latest.netRx)}   ·   TX ${_humanBytes(latest.netTx)}'),
        const SizedBox(height: 12),
        _numberCard('Block I/O', 'Read ${_humanBytes(latest.blockRead)}   ·   Write ${_humanBytes(latest.blockWrite)}'),
      ],
    );
  }

  Widget _chartCard(String title, String value, List<double> history) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
                const Spacer(),
                Text(value),
              ]),
              const SizedBox(height: 8),
              SizedBox(
                height: 80,
                child: LineChart(LineChartData(
                  minY: 0,
                  maxY: 100,
                  titlesData: const FlTitlesData(show: false),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: [for (var i = 0; i < history.length; i++) FlSpot(i.toDouble(), history[i])],
                      isCurved: false,
                      barWidth: 2,
                      dotData: const FlDotData(show: false),
                    ),
                  ],
                )),
              ),
            ],
          ),
        ),
      );

  Widget _numberCard(String title, String value) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold)),
            const Spacer(),
            Text(value),
          ]),
        ),
      );
}
```
**fl_chart adaptation note:** the minimal API used (`LineChart`/`LineChartData`/`LineChartBarData`/`FlSpot`/`FlTitlesData`/`FlGridData`/`FlBorderData`/`FlDotData`) is stable across recent fl_chart majors. If the installed version renames a member or makes one non-const, adapt minimally (keep the sparkline shape) and note it in concerns.

- [ ] **Step 4: Run the screen test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/container_stats_screen_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Add the Stats button to ContainerDetailScreen**

In `app/lib/src/ui/container_detail_screen.dart`, add `import 'container_stats_screen.dart';`, and add a third button to the Logs/Exec `Row` (after the Exec `Expanded`, with a leading `SizedBox(width: 8)`):
```dart
            const SizedBox(width: 8),
            Expanded(child: OutlinedButton.icon(
              icon: const Icon(Icons.monitor_heart),
              label: const Text('Stats'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ContainerStatsScreen(containerId: containerId, containerName: containerName))),
            )),
```

- [ ] **Step 6: Run the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; **all** app tests pass (the existing `container_detail_screen_test.dart` still green — the new Stats button doesn't change its assertions).

- [ ] **Step 7: Commit**

```bash
git add app/lib/src/ui/container_stats_screen.dart app/lib/src/ui/container_detail_screen.dart app/test/ui/container_stats_screen_test.dart
git commit -m "feat(app): ContainerStatsScreen (fl_chart sparklines) + Stats button"
```

---

## Self-Review

**1. Spec coverage:**
- `ContainerStats.fromJson` (CPU%/memory/net/block-io, tolerant) → Task 1. ✓
- `streamContainerStats` (NDJSON, skip malformed) → Task 1. ✓
- `fl_chart` dep → Task 1. ✓
- `StatsNotifier` + rolling windows + `statsProvider` (autoDispose family) → Task 2. ✓
- `ContainerStatsScreen` (fl_chart sparklines + numbers + loading/error) → Task 3. ✓
- Stats button on `ContainerDetailScreen` → Task 3. ✓
- Out of scope (events feed, per-process, persistence, zoom, configurable window) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete. The fl_chart adaptation note is a bounded, explicit instruction (version member names), not a placeholder.

**3. Type consistency:** `ContainerStats({cpuPercent, memoryUsed, memoryLimit, memoryPercent, netRx, netTx, blockRead, blockWrite})` + `fromJson` (Task 1) consumed in Tasks 2/3. `streamContainerStats(id) → Stream<ContainerStats>` (Task 1) used by `StatsNotifier` (Task 2). `StatsState`/`StatsStatus`/`kStatsWindow`/`statsProvider` (Task 2) used by `ContainerStatsScreen` (Task 3). `ContainerStatsScreen({containerId, containerName})` (Task 3) used by the detail Stats button (Task 3). ✓
