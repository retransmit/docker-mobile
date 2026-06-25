# Phase 1D-2b — SSH Transport + UI — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drive Docker over SSH end-to-end — a full `SshTransport` over per-request `dial-stdio` channels, plus the SSH connect form with host-key TOFU.

**Architecture:** `SshTransport` implements the `Transport` contract over an injected `Future<Duplex> Function()` opener (HTTP logic via the D2a `stream_http` primitives; testable with in-memory duplexes). A shared `RealSshConnection` (dartssh2) does the SSH handshake once and vends a cheap dial-stdio channel per request. The `SshForm` orchestrates connect + host-key TOFU and is widget-tested via a fake `SshConnection`.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `http`, `dartssh2` (from D2a).

## Global Constraints

- **Shared client, channel-per-request:** the SSH handshake happens once (`SshConnection.connect`); each `Transport` call opens a fresh dial-stdio channel (`openChannel`).
- **No bearer/Authorization header** on any `SshTransport` request.
- **No `SshConnectionConfig`:** SSH connect is async; the form builds `SshTransport(openDuplex: conn.openChannel)` directly. The sealed `ConnectionConfig` stays Agent/Tls.
- **Reuse `SocketExecChannel`** (extracted to a shared file), do not reimplement.
- **TOFU UX:** `firstUse` → pin; `match` → ok; `mismatch` → warning dialog (Cancel / Trust new key → re-pin). Auth/unreachable → error, no navigation. Fail closed; no accept-any.
- **Pin value:** the dartssh2 host-key fingerprint with `SHA256:` stripped (byte-identical to `fingerprintSha256()`, per D2a).
- **Scope:** app-only; no Go agent changes; do not change Agent/TLS transport behavior. No multi-host map (D3), no agent-forwarding/jump-hosts/keyboard-interactive.
- **Tests never open a real SSH connection** (use a fake `SshConnection`) or touch real platform secure storage (use `InMemoryCredentialStore`).
- **Async/dialog discipline:** capture messenger/navigator BEFORE awaits; mounted-guard post-await `setState`; dispose all controllers.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/transport/duplex_exec_channel.dart       # moved SocketExecChannel (shared by TLS + SSH)
app/lib/src/transport/tls_transport.dart             # import + re-export SocketExecChannel
app/lib/src/transport/ssh/ssh_transport.dart         # SshTransport
app/lib/src/transport/ssh/ssh_connection.dart        # + SshConnection abstract + RealSshConnection
app/lib/src/state/providers.dart                     # + sshConnectionFactoryProvider
app/lib/src/ui/connection_screen.dart                # 3rd SSH segment
app/lib/src/ui/connect/ssh_form.dart                 # SshForm
app/test/...                                           # mirrors (except the live RealSshConnection seam)
```

---

## Task 1: Extract SocketExecChannel to a shared file

**Files:**
- Create: `app/lib/src/transport/duplex_exec_channel.dart`
- Modify: `app/lib/src/transport/tls_transport.dart`
- Test: `app/test/transport/duplex_exec_channel_test.dart`

**Interfaces:**
- Produces: `class SocketExecChannel implements ExecChannel { SocketExecChannel({required Stream<List<int>> input, required void Function(List<int>) onSend, required Future<void> Function() onClose}); }` (now in `duplex_exec_channel.dart`; still importable from `tls_transport.dart` via re-export).

- [ ] **Step 1: Write the failing test (new location)**

Create `app/test/transport/duplex_exec_channel_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/duplex_exec_channel.dart';

void main() {
  test('forwards send, maps output, closes once', () async {
    final sent = <List<int>>[];
    var closes = 0;
    final ch = SocketExecChannel(
      input: Stream.value(utf8.encode('out')),
      onSend: sent.add,
      onClose: () async => closes++,
    );
    expect(utf8.decode(await ch.output.first), 'out');
    ch.send(utf8.encode('in'));
    expect(utf8.decode(sent.single), 'in');
    await ch.close();
    await ch.close(); // idempotent
    ch.send(utf8.encode('after')); // no-op after close
    expect(closes, 1);
    expect(sent.length, 1);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/duplex_exec_channel_test.dart`
Expected: FAIL — `duplex_exec_channel.dart` doesn't exist.

- [ ] **Step 3: Move the class + re-export**

Create `app/lib/src/transport/duplex_exec_channel.dart` (move the class out of `tls_transport.dart` verbatim):
```dart
// ignore_for_file: prefer_initializing_formals
import 'transport.dart';

/// Wraps a raw duplex (a hijacked socket or an SSH dial-stdio channel) as an
/// [ExecChannel]. Shared by the TLS and SSH transports.
class SocketExecChannel implements ExecChannel {
  final Stream<List<int>> _input;
  final void Function(List<int>) _onSend;
  final Future<void> Function() _onClose;
  bool _closed = false;

  SocketExecChannel({
    required Stream<List<int>> input,
    required void Function(List<int>) onSend,
    required Future<void> Function() onClose,
  })  : _input = input,
        _onSend = onSend,
        _onClose = onClose;

  @override
  Stream<List<int>> get output => _input;

  @override
  void send(List<int> data) {
    if (_closed) return;
    _onSend(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _onClose();
  }
}
```
In `app/lib/src/transport/tls_transport.dart`: delete the `SocketExecChannel` class definition, add an import + re-export near the top (after the existing imports):
```dart
import 'duplex_exec_channel.dart';
export 'duplex_exec_channel.dart' show SocketExecChannel;
```
(`hijackExec` in `tls_transport.dart` keeps using `SocketExecChannel` — now from the import.)

- [ ] **Step 4: Run the new test + the full suite (D1 stays green via re-export)**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/duplex_exec_channel_test.dart && flutter analyze && flutter test`
Expected: new test PASS; analyzer clean; **all** existing tests pass (especially `test/transport/tls_transport_test.dart`, which imports `SocketExecChannel` from `tls_transport.dart`).

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/transport/duplex_exec_channel.dart app/lib/src/transport/tls_transport.dart app/test/transport/duplex_exec_channel_test.dart
git commit -m "refactor(app): extract SocketExecChannel to a shared file"
```

---

## Task 2: SshTransport

**Files:**
- Create: `app/lib/src/transport/ssh/ssh_transport.dart`
- Test: `app/test/transport/ssh/ssh_transport_test.dart`

**Interfaces:**
- Consumes: `Transport`/`ExecChannel`/`TransportException` (transport.dart), `Duplex` (ssh_connection.dart), `SocketExecChannel` (duplex_exec_channel.dart), `writeHttpRequest`/`readHttpResponse`/`readBufferedResponse` (stream_http.dart).
- Produces: `class SshTransport implements Transport { SshTransport({required Future<Duplex> Function() openDuplex}); }`.

- [ ] **Step 1: Write the failing test**

Create `app/test/transport/ssh/ssh_transport_test.dart`:
```dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_transport.dart';

Duplex _duplex(List<int> response, List<int> written, {void Function()? onClose}) => Duplex(
      input: Stream.value(response),
      add: written.addAll,
      close: () async => onClose?.call(),
    );

void main() {
  test('get builds the request line + parses the response; no Authorization', () async {
    final written = <int>[];
    final t = SshTransport(openDuplex: () async =>
        _duplex(ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]'), written));
    final resp = await t.get('/containers/json', query: {'all': 'true'});
    expect(resp.statusCode, 200);
    expect(resp.body, '[]');
    final reqText = ascii.decode(written);
    expect(reqText.contains('GET /containers/json?all=true HTTP/1.1'), isTrue);
    expect(reqText.toLowerCase().contains('authorization'), isFalse);
  });

  test('post sends a JSON body + Content-Length', () async {
    final written = <int>[];
    final t = SshTransport(openDuplex: () async =>
        _duplex(ascii.encode('HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n'), written));
    await t.post('/x', body: {'k': 'v'});
    final reqText = ascii.decode(written);
    expect(reqText.contains('POST /x HTTP/1.1'), isTrue);
    expect(reqText.contains('Content-Type: application/json'), isTrue);
    expect(reqText.endsWith('{"k":"v"}'), isTrue);
  });

  test('delete passes query', () async {
    final written = <int>[];
    final t = SshTransport(openDuplex: () async =>
        _duplex(ascii.encode('HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n'), written));
    await t.delete('/containers/x', query: {'force': 'true'});
    expect(ascii.decode(written).contains('DELETE /containers/x?force=true HTTP/1.1'), isTrue);
  });

  test('stream yields body bytes and closes the channel on cancel', () async {
    final input = StreamController<List<int>>();
    var closed = false;
    final conn = Duplex(input: input.stream, add: (_) {}, close: () async => closed = true);
    final t = SshTransport(openDuplex: () async => conn);
    final got = <int>[];
    final sub = t.stream('/c/logs').listen(got.addAll);
    input.add(ascii.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'));
    await pumpEventQueue();
    input.add(ascii.encode('5\r\nhello\r\n'));
    await pumpEventQueue();
    expect(utf8.decode(got), 'hello');
    await sub.cancel();
    expect(closed, isTrue);
    await input.close();
  });

  test('stream surfaces a non-200 as TransportException', () async {
    final t = SshTransport(openDuplex: () async =>
        _duplex(ascii.encode('HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nno!'), <int>[]));
    expect(t.stream('/c/logs').first, throwsA(isA<TransportException>()));
  });

  test('execAttach hijacks: sends Upgrade + body, output is the raw remainder', () async {
    final written = <int>[];
    final t = SshTransport(openDuplex: () async => _duplex(
        ascii.encode('HTTP/1.1 101 UPGRADED\r\nUpgrade: tcp\r\n\r\nshell-output'), written));
    final ch = await t.execAttach('exec1', cols: 80, rows: 24);
    final reqText = ascii.decode(written);
    expect(reqText.contains('POST /exec/exec1/start HTTP/1.1'), isTrue);
    expect(reqText.contains('Connection: Upgrade'), isTrue);
    expect(reqText.contains('Upgrade: tcp'), isTrue);
    expect(reqText.contains('{"Detach":false,"Tty":true}'), isTrue);
    expect(utf8.decode(await ch.output.first), 'shell-output');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ssh/ssh_transport_test.dart`
Expected: FAIL — `SshTransport` undefined.

- [ ] **Step 3: Write the implementation**

Create `app/lib/src/transport/ssh/ssh_transport.dart`:
```dart
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../duplex_exec_channel.dart';
import '../transport.dart';
import 'ssh_connection.dart';
import 'stream_http.dart';

String _pathWithQuery(String path, Map<String, String>? query) =>
    (query == null || query.isEmpty) ? path : Uri(path: path, queryParameters: query).toString();

/// Direct Docker transport over SSH: each call opens a fresh `dial-stdio`
/// channel ([Duplex]) over a shared SSH connection. No bearer token.
class SshTransport implements Transport {
  final Future<Duplex> Function() _openDuplex;
  SshTransport({required Future<Duplex> Function() openDuplex}) : _openDuplex = openDuplex;

  Future<http.Response> _send(String method, String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    final conn = await _openDuplex();
    try {
      final h = <String, String>{...?headers};
      List<int>? bodyBytes;
      if (body != null) {
        bodyBytes = utf8.encode(body is String ? body : jsonEncode(body));
        h['Content-Type'] = 'application/json';
      }
      writeHttpRequest(conn.add,
          method: method, path: _pathWithQuery(path, query), headers: h.isEmpty ? null : h, body: bodyBytes);
      final r = await readBufferedResponse(conn.input);
      return http.Response.bytes(r.body, r.statusCode, headers: r.headers);
    } finally {
      await conn.close();
    }
  }

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) =>
      _send('GET', path, query: query);

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      _send('DELETE', path, query: query);

  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) =>
      _send('POST', path, query: query, body: body, headers: headers);

  Stream<List<int>> _openStream(String method, String path,
      {Map<String, String>? query, Object? body}) {
    final controller = StreamController<List<int>>();
    Duplex? conn;
    StreamSubscription<List<int>>? sub;
    controller.onListen = () async {
      try {
        conn = await _openDuplex();
        final h = <String, String>{};
        List<int>? bodyBytes;
        if (body != null) {
          bodyBytes = utf8.encode(body is String ? body : jsonEncode(body));
          h['Content-Type'] = 'application/json';
        }
        writeHttpRequest(conn!.add,
            method: method, path: _pathWithQuery(path, query), headers: h.isEmpty ? null : h, body: bodyBytes);
        final resp = await readHttpResponse(conn!.input);
        if (resp.statusCode != 200) {
          final b = await resp.body.expand((c) => c).toList();
          controller.addError(TransportException(resp.statusCode, utf8.decode(b, allowMalformed: true)));
          await controller.close();
          await conn!.close();
          return;
        }
        sub = resp.body.listen(
          controller.add,
          onError: controller.addError,
          onDone: () async {
            await controller.close();
            await conn!.close();
          },
          cancelOnError: true,
        );
      } catch (e) {
        controller.addError(e);
        await controller.close();
        await conn?.close();
      }
    };
    controller.onCancel = () async {
      await sub?.cancel();
      await conn?.close();
    };
    return controller.stream;
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) =>
      _openStream('GET', path, query: query);

  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) =>
      _openStream('POST', path, query: query, body: body);

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async {
    final conn = await _openDuplex();
    writeHttpRequest(
      conn.add,
      method: 'POST',
      path: '/exec/$execId/start',
      headers: {'Connection': 'Upgrade', 'Upgrade': 'tcp', 'Content-Type': 'application/json'},
      body: utf8.encode(jsonEncode({'Detach': false, 'Tty': true})),
    );
    final resp = await readHttpResponse(conn.input);
    return SocketExecChannel(input: resp.body, onSend: conn.add, onClose: conn.close);
  }
}
```

- [ ] **Step 4: Run the test + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ssh/ssh_transport_test.dart && flutter analyze`
Expected: PASS (6 tests); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/transport/ssh/ssh_transport.dart app/test/transport/ssh/ssh_transport_test.dart
git commit -m "feat(app): SshTransport over per-request dial-stdio channels"
```

---

## Task 3: SshConnection seam + provider

**Files:**
- Modify: `app/lib/src/transport/ssh/ssh_connection.dart`
- Modify: `app/lib/src/state/providers.dart`
- Test: `app/test/transport/ssh/ssh_connection_test.dart`

**Interfaces:**
- Consumes: `SshCredentials`/`SshAuthMethod` (credential_store.dart), `HostKeyVerifier`/`Duplex` (ssh_connection.dart, D2a), dartssh2.
- Produces:
  - `abstract class SshConnection { Future<void> connect({required HostKeyVerifier verifyHostKey}); Future<Duplex> openChannel(); Future<void> close(); }`
  - `class RealSshConnection implements SshConnection { RealSshConnection(SshCredentials creds); }`
  - `sshConnectionFactoryProvider = Provider<SshConnection Function(SshCredentials)>`

- [ ] **Step 1: Write the failing test**

Create `app/test/transport/ssh/ssh_connection_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';

void main() {
  const creds = SshCredentials(
      host: 'h', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p');

  test('openChannel before connect throws StateError', () {
    final c = RealSshConnection(creds);
    expect(c.openChannel(), throwsA(isA<StateError>()));
  });

  test('sshConnectionFactoryProvider builds a RealSshConnection', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final factory = container.read(sshConnectionFactoryProvider);
    expect(factory(creds), isA<RealSshConnection>());
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ssh/ssh_connection_test.dart`
Expected: FAIL — `RealSshConnection`/`sshConnectionFactoryProvider` undefined.

- [ ] **Step 3: Add the abstraction + dartssh2 impl**

In `app/lib/src/transport/ssh/ssh_connection.dart`, add `import 'dart:typed_data';` if missing, and append:
```dart
/// A live SSH connection to a Docker host: one shared client, a cheap
/// `dial-stdio` channel per request.
abstract class SshConnection {
  Future<void> connect({required HostKeyVerifier verifyHostKey});
  Future<Duplex> openChannel();
  Future<void> close();
}

String _stripSha256Prefix(String fp) => fp.startsWith('SHA256:') ? fp.substring(7) : fp;

class RealSshConnection implements SshConnection {
  final SshCredentials creds;
  SSHClient? _client;
  RealSshConnection(this.creds);

  @override
  Future<void> connect({required HostKeyVerifier verifyHostKey}) async {
    final socket = await SSHSocket.connect(creds.host, creds.port);
    final client = SSHClient(
      socket,
      username: creds.username,
      onPasswordRequest:
          creds.authMethod == SshAuthMethod.password ? () => creds.password ?? '' : null,
      identities: creds.authMethod == SshAuthMethod.key && creds.privateKeyPem != null
          ? SSHKeyPair.fromPem(creds.privateKeyPem!, creds.passphrase)
          : null,
      // dartssh2 hands a precomputed utf8('SHA256:'+base64NoPad(sha256(hostkey)));
      // stripping the prefix yields exactly fingerprintSha256()'s output.
      onVerifyHostKey: (type, fingerprint) =>
          verifyHostKey(_stripSha256Prefix(String.fromCharCodes(fingerprint))),
    );
    _client = client;
    await client.authenticated; // forces handshake + host-key callback + auth
  }

  @override
  Future<Duplex> openChannel() async {
    final client = _client;
    if (client == null) throw StateError('SSH not connected');
    final session = await client.execute('docker system dial-stdio');
    return Duplex(
      input: session.stdout,
      add: (bytes) => session.stdin.add(Uint8List.fromList(bytes)),
      close: () async => session.close(),
    );
  }

  @override
  Future<void> close() async => _client?.close();
}
```
**dartssh2 adaptation note:** this matches the installed 2.18.0 API used in D2a (`SSHSocket.connect`, `SSHClient(onPasswordRequest/identities/onVerifyHostKey)`, `onVerifyHostKey:(String type, Uint8List fingerprint)`, `SSHKeyPair.fromPem`, `client.authenticated`, `execute`→session `stdout`/`stdin`/`close`). If `await client.authenticated` is not the exact member that forces auth in the installed version, adapt to the equivalent (e.g. awaiting the first `execute`) so `connect` resolves only after the host-key callback + auth ran, and note it in concerns. Keep `openChannel`'s StateError guard.

In `app/lib/src/state/providers.dart`, add `import '../transport/ssh/ssh_connection.dart';` and:
```dart
/// Factory for an SSH connection to a host (overridden with a fake in tests).
final sshConnectionFactoryProvider =
    Provider<SshConnection Function(SshCredentials)>((ref) => RealSshConnection.new);
```
(also `import '../storage/credential_store.dart';` is already present from D1.)

- [ ] **Step 4: Run the test + analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ssh/ssh_connection_test.dart && flutter analyze && flutter test`
Expected: PASS (2 tests); analyzer clean; full suite green.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/transport/ssh/ssh_connection.dart app/lib/src/state/providers.dart app/test/transport/ssh/ssh_connection_test.dart
git commit -m "feat(app): SshConnection (shared dartssh2 client) + factory provider"
```

---

## Task 4: SshForm + connect screen segment + TOFU UX

**Files:**
- Create: `app/lib/src/ui/connect/ssh_form.dart`
- Modify: `app/lib/src/ui/connection_screen.dart`
- Modify: `docs/MANUAL-SMOKE-TEST.md`
- Test: `app/test/ui/ssh_form_test.dart`

**Interfaces:**
- Consumes: `SshTransport` (Task 2), `SshConnection`/`sshConnectionFactoryProvider` (Task 3), `verifyHostKey`/`HostKeyVerdict` (host_key.dart), `SshCredentials`/`SshAuthMethod` (credential_store.dart), `transportProvider`/`credentialStoreProvider` (providers.dart).
- Produces: `class SshForm extends ConsumerStatefulWidget`; `ConnectionScreen` gains an SSH segment.

- [ ] **Step 1: Write the failing widget test**

Create `app/test/ui/ssh_form_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_transport.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';

/// Presents a fixed fingerprint and accepts/rejects via the verifier.
class _FakeSshConnection implements SshConnection {
  final String fingerprint;
  _FakeSshConnection(this.fingerprint);
  @override
  Future<void> connect({required HostKeyVerifier verifyHostKey}) async {
    if (!verifyHostKey(fingerprint)) throw Exception('host key rejected');
  }
  @override
  Future<Duplex> openChannel() async =>
      Duplex(input: const Stream.empty(), add: (_) {}, close: () async {});
  @override
  Future<void> close() async {}
}

Widget _wrap(CredentialStore store, SshConnection Function(SshCredentials) factory) => ProviderScope(
      overrides: [
        credentialStoreProvider.overrideWithValue(store),
        sshConnectionFactoryProvider.overrideWithValue(factory),
      ],
      child: const MaterialApp(home: ConnectionScreen()),
    );

Future<void> _gotoSsh(WidgetTester tester) async {
  await tester.tap(find.text('SSH'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('SSH segment reveals fields; auth toggle swaps key<->password', (tester) async {
    await tester.pumpWidget(_wrap(InMemoryCredentialStore(), (_) => _FakeSshConnection('FP')));
    await _gotoSsh(tester);
    expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget); // password is default
    await tester.tap(find.text('Key'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Private key (PEM)'), findsOneWidget);
  });

  testWidgets('invalid input blocks connect', (tester) async {
    final store = InMemoryCredentialStore();
    await tester.pumpWidget(_wrap(store, (_) => _FakeSshConnection('FP')));
    final container = ProviderScope.containerOf(tester.element(find.byType(ConnectionScreen)));
    await _gotoSsh(tester);
    // host left empty
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump();
    expect(find.textContaining('valid'), findsOneWidget);
    expect(container.read(transportProvider), isNull);
  });

  testWidgets('firstUse: connects, pins the fingerprint, sets an SshTransport', (tester) async {
    final store = InMemoryCredentialStore();
    await tester.pumpWidget(_wrap(store, (_) => _FakeSshConnection('FP-NEW')));
    final container = ProviderScope.containerOf(tester.element(find.byType(ConnectionScreen)));
    await _gotoSsh(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '10.0.0.9');
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'root');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(transportProvider), isA<SshTransport>());
    final saved = await store.loadSsh();
    expect(saved!.pinnedHostKey, 'FP-NEW');
    expect(saved.host, '10.0.0.9');
  });

  testWidgets('mismatch: shows the warning dialog; Trust new key re-pins and connects', (tester) async {
    final store = InMemoryCredentialStore();
    // Pre-pin a DIFFERENT fingerprint so the presented one is a mismatch.
    await store.saveSsh(const SshCredentials(
        host: '10.0.0.9', port: 22, username: 'root',
        authMethod: SshAuthMethod.password, password: 'pw', pinnedHostKey: 'FP-OLD'));
    await tester.pumpWidget(_wrap(store, (_) => _FakeSshConnection('FP-NEW')));
    final container = ProviderScope.containerOf(tester.element(find.byType(ConnectionScreen)));
    await _gotoSsh(tester);
    await tester.pumpAndSettle(); // prefill
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('host key'), findsWidgets); // warning dialog
    await tester.tap(find.widgetWithText(TextButton, 'Trust new key'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(transportProvider), isA<SshTransport>());
    expect((await store.loadSsh())!.pinnedHostKey, 'FP-NEW'); // re-pinned
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/ssh_form_test.dart`
Expected: FAIL — `SshForm`/SSH segment not present.

- [ ] **Step 3: Write the SSH form**

Create `app/lib/src/ui/connect/ssh_form.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../storage/credential_store.dart';
import '../../transport/ssh/host_key.dart';
import '../../transport/ssh/ssh_transport.dart';
import '../home_screen.dart';

class SshForm extends ConsumerStatefulWidget {
  const SshForm({super.key});
  @override
  ConsumerState<SshForm> createState() => _SshFormState();
}

class _SshFormState extends ConsumerState<SshForm> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  SshAuthMethod _authMethod = SshAuthMethod.password;
  String? _pinnedHostKey;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final creds = await ref.read(credentialStoreProvider).loadSsh();
    if (creds == null || !mounted) return;
    setState(() {
      _host.text = creds.host;
      _port.text = '${creds.port}';
      _username.text = creds.username;
      _authMethod = creds.authMethod;
      _password.text = creds.password ?? '';
      _key.text = creds.privateKeyPem ?? '';
      _passphrase.text = creds.passphrase ?? '';
      _pinnedHostKey = creds.pinnedHostKey;
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _key.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  SshCredentials _buildCreds(String? pin) => SshCredentials(
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        username: _username.text.trim(),
        authMethod: _authMethod,
        password: _authMethod == SshAuthMethod.password ? _password.text : null,
        privateKeyPem: _authMethod == SshAuthMethod.key ? _key.text : null,
        passphrase: _authMethod == SshAuthMethod.key && _passphrase.text.isNotEmpty ? _passphrase.text : null,
        pinnedHostKey: pin,
      );

  void _connect() {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final user = _username.text.trim();
    if (host.isEmpty || port == null || port < 1 || port > 65535 || user.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Enter a valid host, port (1-65535), and username.')));
      return;
    }
    if (_authMethod == SshAuthMethod.key && _key.text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('A private key is required for key auth.')));
      return;
    }
    if (_authMethod == SshAuthMethod.password && _password.text.isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('A password is required for password auth.')));
      return;
    }
    _attemptConnect(_pinnedHostKey, messenger, navigator);
  }

  Future<void> _attemptConnect(String? pin, ScaffoldMessengerState messenger, NavigatorState navigator) async {
    final creds = _buildCreds(pin);
    final conn = ref.read(sshConnectionFactoryProvider)(creds);
    String? presented;
    var mismatch = false;
    bool verifier(String fp) {
      presented = fp;
      if (verifyHostKey(pin, fp) == HostKeyVerdict.mismatch) {
        mismatch = true;
        return false;
      }
      return true;
    }

    setState(() => _connecting = true);
    try {
      await conn.connect(verifyHostKey: verifier);
    } catch (e) {
      if (!mounted) return;
      setState(() => _connecting = false);
      if (mismatch && presented != null) {
        final trust = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Host key changed'),
            content: const Text(
                'The server host key does not match the pinned key. This could be a man-in-the-middle attack. Trust the new key only if you expected this change.'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Trust new key')),
            ],
          ),
        );
        if (trust == true && mounted) {
          await _attemptConnect(presented, messenger, navigator); // re-pin with the presented key
        }
        return;
      }
      messenger.showSnackBar(SnackBar(content: Text('Connection failed: $e')));
      return;
    }
    if (!mounted) return;
    setState(() => _connecting = false);
    final newPin = pin ?? presented;
    // Persist best-effort; never block connecting.
    try {
      await ref.read(credentialStoreProvider).saveSsh(_buildCreds(newPin));
    } catch (_) {}
    ref.read(transportProvider.notifier).state = SshTransport(openDuplex: conn.openChannel);
    navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host / IP')),
        TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
        TextField(controller: _username, decoration: const InputDecoration(labelText: 'Username')),
        const SizedBox(height: 8),
        SegmentedButton<SshAuthMethod>(
          segments: const [
            ButtonSegment(value: SshAuthMethod.password, label: Text('Password')),
            ButtonSegment(value: SshAuthMethod.key, label: Text('Key')),
          ],
          selected: {_authMethod},
          onSelectionChanged: (s) => setState(() => _authMethod = s.first),
        ),
        if (_authMethod == SshAuthMethod.password)
          TextField(controller: _password, decoration: const InputDecoration(labelText: 'Password'), obscureText: true)
        else ...[
          TextField(controller: _key, decoration: const InputDecoration(labelText: 'Private key (PEM)'), maxLines: 4),
          TextField(controller: _passphrase, decoration: const InputDecoration(labelText: 'Passphrase (optional)'), obscureText: true),
        ],
        const SizedBox(height: 16),
        _connecting
            ? const Center(child: CircularProgressIndicator())
            : FilledButton(onPressed: _connect, child: const Text('Connect')),
      ],
    );
  }
}
```

- [ ] **Step 4: Add the SSH segment to ConnectionScreen**

In `app/lib/src/ui/connection_screen.dart`: add `import 'connect/ssh_form.dart';`, extend the enum to `enum _TransportType { agent, tls, ssh }`, add a 3rd `ButtonSegment`, and a 3rd branch:
```dart
            SegmentedButton<_TransportType>(
              segments: const [
                ButtonSegment(value: _TransportType.agent, label: Text('Agent'), icon: Icon(Icons.dns)),
                ButtonSegment(value: _TransportType.tls, label: Text('TCP+TLS'), icon: Icon(Icons.lock)),
                ButtonSegment(value: _TransportType.ssh, label: Text('SSH'), icon: Icon(Icons.terminal)),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: switch (_type) {
                  _TransportType.agent => const AgentForm(),
                  _TransportType.tls => const TlsForm(),
                  _TransportType.ssh => const SshForm(),
                },
              ),
            ),
```

- [ ] **Step 5: Run the SSH form test + analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/ssh_form_test.dart && flutter analyze && flutter test`
Expected: the SSH form test passes; analyzer clean; **all** app tests pass (the existing `connection_screen_test.dart` still green — Agent default, TLS reachable).

- [ ] **Step 6: Document the manual smoke test**

In `docs/MANUAL-SMOKE-TEST.md`, replace the D2a "step 2" guidance / extend the SSH section with the form path:
```markdown
### Phase 1D-2b — SSH end-to-end via the form

1. Connect → **SSH**. Enter host, port `22`, username; pick **Key** (paste a PEM, optional passphrase) or **Password**.
2. First connect: accept the host key (it is pinned). The container list loads over SSH; open a container → **Logs** stream; **Exec** opens an interactive shell (dial-stdio hijack); **System** loads.
3. Reconnect: the pinned key matches silently.
4. Change the server's host key (or pin a wrong one) and reconnect: the **"Host key changed"** dialog appears; **Cancel** aborts, **Trust new key** re-pins and connects.
```

- [ ] **Step 7: Commit**

```bash
git add app/lib/src/ui/connect/ssh_form.dart app/lib/src/ui/connection_screen.dart app/test/ui/ssh_form_test.dart docs/MANUAL-SMOKE-TEST.md
git commit -m "feat(app): SSH connect form + segment + host-key TOFU UX"
```

---

## Self-Review

**1. Spec coverage:**
- Extract `SocketExecChannel` → shared file (reused, D1 green) → Task 1. ✓
- `SshTransport` (get/post/delete buffered, stream/postStream streamed + close-on-cancel, execAttach hijack reusing `SocketExecChannel`) → Task 2. ✓
- `SshConnection` abstract + `RealSshConnection` (shared dartssh2 client, connect+TOFU, openChannel, close) + `sshConnectionFactoryProvider` → Task 3. ✓
- `SshForm` + 3rd SSH segment + key/password toggle + TOFU (firstUse pin / match / mismatch warn+trust) + prefill/persist → Task 4. ✓
- No bearer header; no `SshConnectionConfig`; shared-client/channel-per-request; pin = stripped fingerprint → Tasks 2/3/4. ✓
- Manual smoke (live form path) → Task 4 Step 6. ✓
- Out of scope (multi-host, agent-forwarding, agent/TLS/Go changes) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete. The dartssh2 seam carries an explicit adaptation note but ships concrete code matching the D2a-verified API.

**3. Type consistency:** `SocketExecChannel({input, onSend, onClose})` (Task 1) is used by `SshTransport.execAttach` (Task 2) and the existing `hijackExec`. `SshTransport({openDuplex: Future<Duplex> Function()})` (Task 2) is constructed in Task 4 (`SshTransport(openDuplex: conn.openChannel)`). `Duplex` (D2a) is consumed by both. `SshConnection.connect({verifyHostKey})`/`openChannel()`/`close()` + `RealSshConnection(creds)` + `sshConnectionFactoryProvider` (Task 3) are consumed by Task 4's form + the fake. `verifyHostKey(String?, String)→HostKeyVerdict` + `HostKeyVerdict.mismatch` (D2a) used in the form's verifier. `SshCredentials({...pinnedHostKey})`/`SshAuthMethod` (D2a) built in `_buildCreds`. `HostKeyVerifier = bool Function(String)` (D2a) is the verifier closure's type. ✓
