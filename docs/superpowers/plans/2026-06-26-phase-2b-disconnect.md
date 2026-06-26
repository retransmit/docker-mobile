# Phase 2B — Disconnect / Switch-Host Flow — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Disconnect action that closes the active transport's client and returns to the profiles list, so users can cleanly switch hosts.

**Architecture:** Add `Transport.close()` (each impl closes its HTTP/SSH client); a `disconnect(context, ref)` helper pops to the profiles list, nulls the transport, and closes it; a confirm-dialog-guarded Disconnect action on the System dashboard.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `http` (all existing).

## Global Constraints

- **App-only slice:** no agent changes; no new deps.
- **`Transport.close()` on the interface** — `AgentTransport`/`TlsTransport` close their `http.Client`; `SshTransport` awaits an injected `onClose` (= `SshConnection.close`); `ConnectionLauncher._launchSsh` passes `conn.close`.
- **Pop-first ordering** in `disconnect`: `popUntil((r) => r.isFirst)` BEFORE nulling `transportProvider` + `await transport?.close()` (so HomeScreen's providers dispose without an error flash).
- **Placement:** one `IconButton(Icons.logout)` on `SystemScreen`'s app bar → confirm dialog ("Disconnect from this daemon?") → `disconnect`.
- **`close()` is best-effort + idempotent:** null-safe `onClose`; closing an already-closed client is harmless.
- **Every existing `Transport` test fake** gains `@override Future<void> close() async {}` (use the analyzer to enumerate them — see Task 1 Step 4).
- **Async/dialog discipline:** capture navigator before awaits; `context.mounted` guard after the confirm dialog.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/transport/transport.dart            # + Future<void> close() on the interface
app/lib/src/transport/agent_transport.dart      # + close() -> _client.close()
app/lib/src/transport/tls_transport.dart        # + close() -> _client.close()
app/lib/src/transport/ssh/ssh_transport.dart    # + onClose + close()
app/lib/src/connect/connection_launcher.dart    # SshTransport(..., onClose: conn.close)
app/lib/src/connect/disconnect.dart             # disconnect(context, ref)
app/lib/src/ui/system_screen.dart               # + Disconnect app-bar action + confirm dialog
app/test/**                                       # + close() stub on every Transport fake; new tests
```

---

## Task 1: Transport.close() across the interface + impls

**Files:**
- Modify: `app/lib/src/transport/transport.dart`, `agent_transport.dart`, `tls_transport.dart`, `ssh/ssh_transport.dart`, `connect/connection_launcher.dart`
- Modify: every `app/test/**` file with a `Transport` fake (add a `close()` stub — enumerated by the analyzer in Step 4)
- Test: `app/test/transport/transport_close_test.dart`

**Interfaces:**
- Produces: `Future<void> close()` on `Transport` (and all three impls); `SshTransport({required Future<Duplex> Function() openDuplex, Future<void> Function()? onClose})`.

- [ ] **Step 1: Write the failing test**

Create `app/test/transport/transport_close_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/agent_transport.dart';
import 'package:docker_mobile/src/transport/tls_transport.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_transport.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';

class _FakeClient extends http.BaseClient {
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream.empty(), 200);
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test('AgentTransport.close() closes its client', () async {
    final c = _FakeClient();
    await AgentTransport(baseUri: Uri.parse('http://h:8080'), token: 't', client: c).close();
    expect(c.closed, isTrue);
  });

  test('TlsTransport.close() closes its client', () async {
    final c = _FakeClient();
    await TlsTransport(baseUri: Uri.parse('https://h:2376'), client: c).close();
    expect(c.closed, isTrue);
  });

  test('SshTransport.close() invokes onClose (and is null-safe without it)', () async {
    var closed = false;
    await SshTransport(
      openDuplex: () async => Duplex(input: const Stream.empty(), add: (_) {}, close: () async {}),
      onClose: () async => closed = true,
    ).close();
    expect(closed, isTrue);

    // No onClose -> close() is a harmless no-op.
    await SshTransport(
      openDuplex: () async => Duplex(input: const Stream.empty(), add: (_) {}, close: () async {}),
    ).close();
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/transport_close_test.dart`
Expected: FAIL — `close()` / `onClose` undefined.

- [ ] **Step 3: Add `close()` to the interface + impls + launcher**

In `app/lib/src/transport/transport.dart`, add to `abstract class Transport` (after the `postStream` declaration):
```dart
  /// Closes the underlying client/connection. Best-effort; safe to call once.
  Future<void> close();
```
In `app/lib/src/transport/agent_transport.dart`, add to `AgentTransport`:
```dart
  @override
  Future<void> close() async => _client.close();
```
In `app/lib/src/transport/tls_transport.dart`, add to `TlsTransport`:
```dart
  @override
  Future<void> close() async => _client.close();
```
In `app/lib/src/transport/ssh/ssh_transport.dart`, add the field + constructor param + method. Change the constructor to:
```dart
  final Future<Duplex> Function() _openDuplex;
  final Future<void> Function()? _onClose;
  SshTransport({required Future<Duplex> Function() openDuplex, Future<void> Function()? onClose})
      : _openDuplex = openDuplex,
        _onClose = onClose;
```
and add:
```dart
  @override
  Future<void> close() async => await _onClose?.call();
```
In `app/lib/src/connect/connection_launcher.dart`, in `_launchSsh` change the `SshTransport(...)` construction to pass `onClose`:
```dart
  ref.read(transportProvider.notifier).state = SshTransport(openDuplex: conn.openChannel, onClose: conn.close);
```

- [ ] **Step 4: Add the `close()` stub to every Transport fake (analyzer-driven)**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze`
The analyzer now reports `Missing concrete implementation of 'Transport.close'` for every test fake. For EACH flagged class (a `class _Fake... implements Transport` in `app/test/**`), add this stub inside the class:
```dart
  @override
  Future<void> close() async {}
```
Re-run `flutter analyze` until it reports **No issues found!** (every flagged fake handled). Do NOT change any other behavior in those fakes.

- [ ] **Step 5: Run the new test + analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/transport_close_test.dart && flutter analyze && flutter test`
Expected: the 3 close tests pass; analyzer clean; **all** app tests pass.

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/transport/ app/lib/src/connect/connection_launcher.dart app/test/
git commit -m "feat(app): Transport.close() + per-transport client teardown"
```

---

## Task 2: disconnect() + System Disconnect action

**Files:**
- Create: `app/lib/src/connect/disconnect.dart`
- Modify: `app/lib/src/ui/system_screen.dart`
- Test: `app/test/connect/disconnect_test.dart`, and extend `app/test/ui/system_screen_test.dart`

**Interfaces:**
- Consumes: `transportProvider` (providers.dart), `Transport.close()` (Task 1).
- Produces: `Future<void> disconnect(BuildContext context, WidgetRef ref)`; a Disconnect action on `SystemScreen`.

- [ ] **Step 1: Write the failing disconnect test**

Create `app/test/connect/disconnect_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/connect/disconnect.dart';

class _FakeTransport implements Transport {
  bool closed = false;
  @override
  Future<void> close() async => closed = true;
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async => http.Response('', 200);
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
  testWidgets('disconnect pops to the first route, nulls and closes the transport', (tester) async {
    final fake = _FakeTransport();
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => fake)],
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          container = ProviderScope.containerOf(ctx);
          return Scaffold(
            body: Center(child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => Consumer(builder: (c, ref, _) => Scaffold(
                  body: Center(child: ElevatedButton(
                    onPressed: () => disconnect(c, ref),
                    child: const Text('disconnect'),
                  )),
                )),
              )),
              child: const Text('go'),
            )),
          );
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('disconnect'));
    await tester.pumpAndSettle();

    expect(container.read(transportProvider), isNull);
    expect(fake.closed, isTrue);
    expect(find.text('go'), findsOneWidget); // back on the first route
    expect(find.text('disconnect'), findsNothing);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/connect/disconnect_test.dart`
Expected: FAIL — `disconnect` undefined.

- [ ] **Step 3: Write the disconnect helper**

Create `app/lib/src/connect/disconnect.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';

/// Tears down the active connection and returns to the profiles list:
/// pop first (disposing the home screen + its providers), then detach and
/// close the transport (best-effort).
Future<void> disconnect(BuildContext context, WidgetRef ref) async {
  final navigator = Navigator.of(context);
  final transport = ref.read(transportProvider);
  navigator.popUntil((r) => r.isFirst);
  ref.read(transportProvider.notifier).state = null;
  await transport?.close();
}
```

- [ ] **Step 4: Run the disconnect test**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/connect/disconnect_test.dart`
Expected: PASS.

- [ ] **Step 5: Write the failing System action test**

In `app/test/ui/system_screen_test.dart`, add a test (keep the existing ones). It pushes `SystemScreen` on top of a first route so `popUntil` has a target, taps Disconnect, confirms, and asserts the transport is nulled. Add at the end of `main()`:
```dart
  testWidgets('Disconnect action confirms then nulls the transport', (tester) async {
    final t = _FakeTransport(); // the file's existing dashboard fake
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          container = ProviderScope.containerOf(ctx);
          return Scaffold(
            body: Center(child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute(builder: (_) => const SystemScreen())),
              child: const Text('open'),
            )),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect from this daemon?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(container.read(transportProvider), isNull);
    expect(find.text('open'), findsOneWidget); // popped back
  });
```
(If the existing fake in `system_screen_test.dart` is not named `_FakeTransport`, use whatever the file already defines — it already serves `/info`, `/version`, `/system/df`. It will gain a `close()` stub from Task 1.)

- [ ] **Step 6: Run to verify the new test fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/system_screen_test.dart`
Expected: FAIL — no `Icons.logout` action yet.

- [ ] **Step 7: Add the Disconnect action to SystemScreen**

In `app/lib/src/ui/system_screen.dart`, add `import '../connect/disconnect.dart';`, and add a Disconnect `IconButton` to the app bar `actions` (after the existing refresh action):
```dart
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Disconnect',
            onPressed: () async {
              final confirmed = await showDialog<bool>(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text('Disconnect'),
                  content: const Text('Disconnect from this daemon?'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                    TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Disconnect')),
                  ],
                ),
              );
              if (confirmed == true && context.mounted) await disconnect(context, ref);
            },
          ),
```
(`SystemScreen` is a `ConsumerWidget`, so `ref` is the `build` parameter and `context` is in scope.)

- [ ] **Step 8: Run the System test + analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/system_screen_test.dart && flutter analyze && flutter test`
Expected: PASS; analyzer clean; **all** app tests pass.

- [ ] **Step 9: Commit**

```bash
git add app/lib/src/connect/disconnect.dart app/lib/src/ui/system_screen.dart app/test/connect/disconnect_test.dart app/test/ui/system_screen_test.dart
git commit -m "feat(app): disconnect flow + System Disconnect action"
```

---

## Self-Review

**1. Spec coverage:**
- `Transport.close()` on the interface + 3 impls + SSH `onClose` + launcher wiring → Task 1. ✓
- Fake `close()` stubs (analyzer-enumerated) → Task 1 Step 4. ✓
- `disconnect(context, ref)` (pop-first, null, close) → Task 2. ✓
- System Disconnect action + confirm dialog → Task 2. ✓
- Out of scope (reconnect/keep-alive, per-tab, host name, shared FakeTransport refactor) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". The fake-stub sweep is concrete (exact stub + analyzer as the checklist). The System test notes the existing fake's name may differ — that's a real instruction, not a placeholder.

**3. Type consistency:** `Future<void> close()` (Task 1) is the method `disconnect` calls via `transport?.close()` (Task 2). `SshTransport({openDuplex, onClose})` (Task 1) used in `connection_launcher.dart` (Task 1). `disconnect(BuildContext, WidgetRef)` (Task 2) called by `SystemScreen` (Task 2). `AgentTransport({client})`/`TlsTransport({client})` are existing constructors used by the close tests. ✓
