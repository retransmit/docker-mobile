# Phase 2D — Daemon Events Feed — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A live, newest-first daemon events feed with type-filter chips, reached from the System dashboard.

**Architecture:** A pure `DockerEvent` model parses each `/events` NDJSON line; `streamEvents` exposes the stream; an `EventsNotifier` (`StateNotifier`) keeps a newest-first ring buffer + a type filter behind an autoDispose provider; `EventsScreen` renders filter chips + the feed, reached via an Events app-bar action on `SystemScreen`.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod` (all existing).

## Global Constraints

- **App-only slice:** no agent changes; NO new `Transport` methods (use existing `stream`). All calls go through `DockerApiClient`.
- **Stream:** `GET /events`, NDJSON byte-buffered (same pattern as `streamContainerStats`); malformed lines skipped.
- **Buffer:** `kEventsBufferCap = 500`, newest first (prepend; trim the tail). Stream canceled on screen leave via an autoDispose provider.
- **Filter:** client-side type chips — All (null) · Containers (`container`) · Images (`image`) · Networks (`network`) · Volumes (`volume`).
- **Target label:** `Actor.Attributes.name` (non-empty) else short (`≤12`) `Actor.ID`. **Time:** prefer `timeNano` (µs), else `time` (sec); shown local `HH:mm:ss`.
- **Entry point:** an Events `IconButton(Icons.bolt)` on `SystemScreen` app bar (between refresh and the disconnect/logout action) → pushed `EventsScreen`.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/api/models/docker_event.dart          # DockerEvent + fromJson
app/lib/src/api/docker_api_client.dart            # + streamEvents
app/lib/src/state/events_notifier.dart            # EventsState + EventsNotifier + eventsProvider + kEventsBufferCap
app/lib/src/ui/events_screen.dart                 # EventsScreen (filter chips + feed)
app/lib/src/ui/system_screen.dart                 # + Events app-bar action
app/test/...                                        # mirrors the above
```

---

## Task 1: DockerEvent model + streamEvents

**Files:**
- Create: `app/lib/src/api/models/docker_event.dart`
- Modify: `app/lib/src/api/docker_api_client.dart`
- Test: `app/test/api/models/docker_event_test.dart`, `app/test/api/docker_api_client_events_test.dart`

**Interfaces:**
- Produces:
  - `class DockerEvent { final String type, action, target; final DateTime? time; const DockerEvent({...}); factory DockerEvent.fromJson(Map<String,dynamic>); }`
  - `DockerApiClient.streamEvents() -> Stream<DockerEvent>`

- [ ] **Step 1: Write the failing model test**

Create `app/test/api/models/docker_event_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_event.dart';

void main() {
  test('parses type/action/target(name) and time from timeNano', () {
    final e = DockerEvent.fromJson({
      'Type': 'container',
      'Action': 'start',
      'Actor': {'ID': 'abcdef0123456789', 'Attributes': {'name': 'web', 'image': 'nginx'}},
      'timeNano': 1700000000000000000,
    });
    expect(e.type, 'container');
    expect(e.action, 'start');
    expect(e.target, 'web');
    expect(e.time, isNotNull);
    expect(e.time!.microsecondsSinceEpoch, 1700000000000000000 ~/ 1000);
  });

  test('falls back to short ID when no name; tolerates missing Actor', () {
    final e = DockerEvent.fromJson({
      'Type': 'image',
      'Action': 'pull',
      'Actor': {'ID': 'sha256abcdef0123456789'},
    });
    expect(e.target, 'sha256abcdef'); // first 12 chars
    final e2 = DockerEvent.fromJson({'Type': 'network', 'Action': 'connect'});
    expect(e2.target, '');
    expect(e2.time, isNull);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/docker_event_test.dart`
Expected: FAIL — `DockerEvent` undefined.

- [ ] **Step 3: Write the model**

Create `app/lib/src/api/models/docker_event.dart`:
```dart
class DockerEvent {
  final String type;
  final String action;
  final String target;
  final DateTime? time;

  const DockerEvent({required this.type, required this.action, required this.target, this.time});

  factory DockerEvent.fromJson(Map<String, dynamic> json) {
    final actor = (json['Actor'] as Map?) ?? const {};
    final attrs = (actor['Attributes'] as Map?) ?? const {};
    final id = actor['ID'] as String? ?? '';
    final name = attrs['name'] as String?;
    final target = (name != null && name.isNotEmpty) ? name : (id.length > 12 ? id.substring(0, 12) : id);
    final timeNano = (json['timeNano'] as num?)?.toInt();
    final timeSec = (json['time'] as num?)?.toInt();
    final time = timeNano != null
        ? DateTime.fromMicrosecondsSinceEpoch(timeNano ~/ 1000)
        : (timeSec != null ? DateTime.fromMillisecondsSinceEpoch(timeSec * 1000) : null);
    return DockerEvent(
      type: json['Type'] as String? ?? '',
      action: json['Action'] as String? ?? '',
      target: target,
      time: time,
    );
  }
}
```

- [ ] **Step 4: Run the model test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/docker_event_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Write the failing client test**

Create `app/test/api/docker_api_client_events_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _FakeTransport implements Transport {
  String? lastStreamPath;
  final List<List<int>> chunks;
  _FakeTransport(this.chunks);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    lastStreamPath = path;
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

void main() {
  test('streamEvents parses NDJSON across chunk boundaries', () async {
    final l1 = '{"Type":"container","Action":"start","Actor":{"Attributes":{"name":"a"}}}';
    final l2 = '{"Type":"image","Action":"pull","Actor":{"Attributes":{"name":"nginx"}}}';
    final all = '$l1\n$l2\n';
    final cut = l1.length - 4;
    final t = _FakeTransport([utf8.encode(all.substring(0, cut)), utf8.encode(all.substring(cut))]);
    final events = await DockerApiClient(t).streamEvents().toList();

    expect(t.lastStreamPath, '/events');
    expect(events.length, 2);
    expect(events[0].type, 'container');
    expect(events[1].target, 'nginx');
  });

  test('skips a malformed NDJSON line', () async {
    final t = _FakeTransport([utf8.encode('garbage\n{"Type":"volume","Action":"create"}\n')]);
    final events = await DockerApiClient(t).streamEvents().toList();
    expect(events.length, 1);
    expect(events.single.type, 'volume');
  });
}
```

- [ ] **Step 6: Add `streamEvents`**

In `app/lib/src/api/docker_api_client.dart`, add `import 'models/docker_event.dart';` and append inside `DockerApiClient`:
```dart
  Stream<DockerEvent> streamEvents() async* {
    final raw = transport.stream('/events');
    final buffer = <int>[];
    await for (final chunk in raw) {
      buffer.addAll(chunk);
      var nl = buffer.indexOf(0x0A);
      while (nl != -1) {
        final line = utf8.decode(buffer.sublist(0, nl), allowMalformed: true).trim();
        buffer.removeRange(0, nl + 1);
        if (line.isNotEmpty) {
          try {
            yield DockerEvent.fromJson(jsonDecode(line) as Map<String, dynamic>);
          } catch (_) {
            // skip a malformed/partial line
          }
        }
        nl = buffer.indexOf(0x0A);
      }
    }
  }
```

- [ ] **Step 7: Run both tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/api/models/docker_event_test.dart test/api/docker_api_client_events_test.dart && flutter analyze`
Expected: PASS (4 tests); analyzer clean.

- [ ] **Step 8: Commit**

```bash
git add app/lib/src/api/models/docker_event.dart app/lib/src/api/docker_api_client.dart app/test/api/models/docker_event_test.dart app/test/api/docker_api_client_events_test.dart
git commit -m "feat(app): DockerEvent model + streamEvents"
```

---

## Task 2: EventsNotifier + provider

**Files:**
- Create: `app/lib/src/state/events_notifier.dart`
- Test: `app/test/state/events_notifier_test.dart`

**Interfaces:**
- Consumes: `DockerEvent`/`streamEvents` (Task 1), `dockerClientProvider` (providers.dart).
- Produces: `const int kEventsBufferCap`; `enum EventsStatus { streaming, error }`; `class EventsState { List<DockerEvent> events; String? filterType; EventsStatus status; String? error; List<DockerEvent> get visibleEvents; copyWith(...); }`; `class EventsNotifier extends StateNotifier<EventsState> { EventsNotifier(DockerApiClient); void setFilter(String?); }`; `eventsProvider` (autoDispose).

- [ ] **Step 1: Write the failing test**

Create `app/test/state/events_notifier_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/events_notifier.dart';

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

void main() {
  test('prepends newest-first, caps the buffer, and filters by type', () async {
    final lines = StringBuffer();
    for (var i = 0; i < kEventsBufferCap + 5; i++) {
      lines.writeln('{"Type":"container","Action":"start","Actor":{"Attributes":{"name":"c$i"}}}');
    }
    lines.writeln('{"Type":"image","Action":"pull","Actor":{"Attributes":{"name":"nginx"}}}');
    final client = DockerApiClient(_FakeTransport(() => Stream.value(utf8.encode(lines.toString()))));
    final n = EventsNotifier(client);
    await pumpEventQueue();

    expect(n.state.events.length, kEventsBufferCap); // capped
    expect(n.state.events.first.target, 'nginx'); // newest first (last fed)
    expect(n.state.visibleEvents.length, kEventsBufferCap); // no filter

    n.setFilter('image');
    expect(n.state.visibleEvents.length, 1);
    expect(n.state.visibleEvents.single.type, 'image');

    n.setFilter(null);
    expect(n.state.visibleEvents.length, kEventsBufferCap);
    n.dispose();
  });

  test('a stream error sets error status', () async {
    final client = DockerApiClient(_FakeTransport(() => Stream.error(Exception('boom'))));
    final n = EventsNotifier(client);
    await pumpEventQueue();
    expect(n.state.status, EventsStatus.error);
    expect(n.state.error, contains('boom'));
    n.dispose();
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/state/events_notifier_test.dart`
Expected: FAIL — `EventsNotifier` undefined.

- [ ] **Step 3: Write the notifier + provider**

Create `app/lib/src/state/events_notifier.dart`:
```dart
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/docker_event.dart';
import 'providers.dart';

const int kEventsBufferCap = 500;

enum EventsStatus { streaming, error }

class EventsState {
  final List<DockerEvent> events;
  final String? filterType;
  final EventsStatus status;
  final String? error;

  const EventsState({
    this.events = const [],
    this.filterType,
    this.status = EventsStatus.streaming,
    this.error,
  });

  List<DockerEvent> get visibleEvents =>
      filterType == null ? events : events.where((e) => e.type == filterType).toList();

  EventsState copyWith({
    List<DockerEvent>? events,
    String? filterType,
    bool clearFilter = false,
    EventsStatus? status,
    String? error,
  }) =>
      EventsState(
        events: events ?? this.events,
        filterType: clearFilter ? null : (filterType ?? this.filterType),
        status: status ?? this.status,
        error: error ?? this.error,
      );
}

class EventsNotifier extends StateNotifier<EventsState> {
  StreamSubscription<DockerEvent>? _sub;

  EventsNotifier(DockerApiClient client) : super(const EventsState()) {
    _sub = client.streamEvents().listen(
      (e) {
        final next = [e, ...state.events];
        state = state.copyWith(
          events: next.length > kEventsBufferCap ? next.sublist(0, kEventsBufferCap) : next,
          status: EventsStatus.streaming,
        );
      },
      onError: (Object e) => state = state.copyWith(status: EventsStatus.error, error: '$e'),
      cancelOnError: true,
    );
  }

  void setFilter(String? type) =>
      state = type == null ? state.copyWith(clearFilter: true) : state.copyWith(filterType: type);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// Live daemon events; auto-disposes (and cancels the stream) when the screen
/// that watches it leaves.
final eventsProvider = StateNotifierProvider.autoDispose<EventsNotifier, EventsState>((ref) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return EventsNotifier(client);
});
```

- [ ] **Step 4: Run the test + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/state/events_notifier_test.dart && flutter analyze`
Expected: PASS (2 tests); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/state/events_notifier.dart app/test/state/events_notifier_test.dart
git commit -m "feat(app): EventsNotifier + eventsProvider (ring buffer + type filter)"
```

---

## Task 3: EventsScreen + System Events action

**Files:**
- Create: `app/lib/src/ui/events_screen.dart`
- Modify: `app/lib/src/ui/system_screen.dart`
- Test: `app/test/ui/events_screen_test.dart`

**Interfaces:**
- Consumes: `eventsProvider`/`EventsState`/`EventsStatus` (Task 2), `transportProvider`/`dockerClientProvider` (providers.dart).
- Produces: `class EventsScreen extends ConsumerWidget`; an Events action on `SystemScreen`.

- [ ] **Step 1: Write the failing test**

Create `app/test/ui/events_screen_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/events_screen.dart';
import 'package:docker_mobile/src/ui/system_screen.dart';

class _FakeTransport implements Transport {
  final List<int>? eventsBytes;
  _FakeTransport({this.eventsBytes});
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) =>
      (path == '/events' && eventsBytes != null) ? Stream.value(eventsBytes!) : const Stream.empty();
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path == '/info') return http.Response('{"ServerVersion":"27","NCPU":1,"Driver":"overlay2"}', 200);
    if (path == '/version') return http.Response('{"Version":"27","ApiVersion":"1.46"}', 200);
    if (path == '/system/df') return http.Response('{"Images":[],"Containers":[],"Volumes":[],"BuildCache":[]}', 200);
    return http.Response('{}', 200);
  }
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

const _events =
    '{"Type":"container","Action":"start","Actor":{"Attributes":{"name":"web"}}}\n'
    '{"Type":"image","Action":"pull","Actor":{"Attributes":{"name":"nginx"}}}\n';

Widget _wrap(Transport t, Widget child) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('renders events; the Containers chip filters the feed', (tester) async {
    await tester.pumpWidget(_wrap(_FakeTransport(eventsBytes: utf8.encode(_events)), const EventsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('nginx'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Containers'));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('nginx'), findsNothing); // image filtered out
  });

  testWidgets('the System Events action opens the events screen', (tester) async {
    await tester.pumpWidget(_wrap(_FakeTransport(), const SystemScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pumpAndSettle();
    expect(find.byType(EventsScreen), findsOneWidget);
    expect(find.textContaining('No events'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/events_screen_test.dart`
Expected: FAIL — `EventsScreen` undefined / no `Icons.bolt` action.

- [ ] **Step 3: Write the screen**

Create `app/lib/src/ui/events_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/events_notifier.dart';

class EventsScreen extends ConsumerWidget {
  const EventsScreen({super.key});

  static const List<(String?, String)> _chips = [
    (null, 'All'),
    ('container', 'Containers'),
    ('image', 'Images'),
    ('network', 'Networks'),
    ('volume', 'Volumes'),
  ];

  IconData _icon(String type) => switch (type) {
        'container' => Icons.inventory,
        'image' => Icons.layers,
        'network' => Icons.hub,
        'volume' => Icons.storage,
        _ => Icons.bolt,
      };

  String _time(DateTime? t) {
    if (t == null) return '';
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(eventsProvider);
    final notifier = ref.read(eventsProvider.notifier);
    return Scaffold(
      appBar: AppBar(title: const Text('Events')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8),
            child: Wrap(
              spacing: 8,
              children: [
                for (final (type, label) in _chips)
                  FilterChip(
                    label: Text(label),
                    selected: state.filterType == type,
                    onSelected: (_) => notifier.setFilter(type),
                  ),
              ],
            ),
          ),
          Expanded(
            child: state.status == EventsStatus.error
                ? Center(child: Text('Error: ${state.error}'))
                : state.visibleEvents.isEmpty
                    ? const Center(child: Text('No events yet.'))
                    : ListView.builder(
                        itemCount: state.visibleEvents.length,
                        itemBuilder: (context, i) {
                          final e = state.visibleEvents[i];
                          return ListTile(
                            dense: true,
                            leading: Icon(_icon(e.type)),
                            title: Text('${e.type} · ${e.action}'),
                            subtitle: Text(e.target),
                            trailing: Text(_time(e.time)),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run the screen test (feed + filter) to verify it passes for EventsScreen**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/events_screen_test.dart`
Expected: the first test passes; the second still FAILS (no `Icons.bolt` action on `SystemScreen` yet).

- [ ] **Step 5: Add the Events action to SystemScreen**

In `app/lib/src/ui/system_screen.dart`, add `import 'events_screen.dart';`, and insert an Events `IconButton` into the app-bar `actions` **between** the existing refresh and the disconnect/logout actions:
```dart
          IconButton(
            icon: const Icon(Icons.bolt),
            tooltip: 'Events',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const EventsScreen()),
            ),
          ),
```

- [ ] **Step 6: Run the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/events_screen_test.dart && flutter analyze && flutter test`
Expected: both events_screen tests pass; analyzer clean; **all** app tests pass (the existing `system_screen_test.dart` still green — the new action doesn't change its assertions).

- [ ] **Step 7: Commit**

```bash
git add app/lib/src/ui/events_screen.dart app/lib/src/ui/system_screen.dart app/test/ui/events_screen_test.dart
git commit -m "feat(app): EventsScreen (filter chips + feed) + System Events action"
```

---

## Self-Review

**1. Spec coverage:**
- `DockerEvent.fromJson` (type/action/target/time, tolerant) → Task 1. ✓
- `streamEvents` (NDJSON, skip malformed) → Task 1. ✓
- `EventsNotifier` (prepend, cap, filter) + `eventsProvider` (autoDispose) → Task 2. ✓
- `EventsScreen` (filter chips + feed + empty/error) → Task 3. ✓
- System Events action → Task 3. ✓
- Out of scope (server-side filter, tap-to-jump, persistence, search, notifications) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete.

**3. Type consistency:** `DockerEvent({type, action, target, time})` + `fromJson` (Task 1) consumed in Tasks 2/3. `streamEvents() → Stream<DockerEvent>` (Task 1) used by `EventsNotifier` (Task 2). `EventsState`/`EventsStatus`/`kEventsBufferCap`/`eventsProvider`/`setFilter` (Task 2) used by `EventsScreen` (Task 3). `EventsScreen` (Task 3) opened by the System action (Task 3). The `(String?, String)` chip records and `state.filterType == type` selection are internally consistent. ✓
