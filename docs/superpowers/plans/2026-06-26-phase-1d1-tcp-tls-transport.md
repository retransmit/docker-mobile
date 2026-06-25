# Phase 1D-1 — TCP+TLS (mTLS) Transport — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect the app directly to a Docker daemon over mutual-TLS (no agent), satisfying the existing `Transport` contract client-side.

**Architecture:** A `TlsTransport` built on dart:io `HttpClient`/`SecurityContext`: HTTP surface via `IOClient`, streaming via a cancelable streamed request, and a client-side exec hijack (`/exec/{id}/start` Upgrade → `detachSocket()`) replacing the agent's WS bridge. A CA-pinning TLS builder with an opt-in insecure mode, minimal secure storage for cert material, and a transport-type-aware connect form.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `http` (+ `http/io_client.dart`), dart:io TLS, `flutter_secure_storage` (new).

## Global Constraints

- **No bearer token** on any `TlsTransport` request — mTLS is the authentication.
- **Server verification:** CA-pinned by default (`SecurityContext.setTrustedCertificatesBytes`); an **off-by-default** insecure toggle sets `httpClient.badCertificateCallback = (_,_,_) => true`. Malformed PEM → `TlsConfigException`.
- **Exec:** TTY exec, raw stream (no stdcopy framing); size via the existing `resizeExec` POST. Default daemon port `2376`.
- **Credential input:** paste PEM only (no `file_picker`). **Persistence:** one "last connection" slot in secure storage; multi-profile is D3.
- **Scope:** app-only; no Go agent changes; do not change `AgentTransport` behavior. No SSH (D2), no profiles (D3), no file-picker.
- **Async/dialog discipline:** capture messenger/navigator BEFORE any await; mounted-guard post-await `setState`; no leaked controllers.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash). `openssl` ships with Git for Windows.
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; work on a feature branch.

---

## File Structure

```
app/lib/src/storage/credential_store.dart         # TlsCredentials + CredentialStore (secure + in-memory)
app/lib/src/transport/tls_security.dart           # buildTlsHttpClient + TlsConfigException
app/lib/src/transport/tls_transport.dart          # TlsTransport + SocketExecChannel + hijackExec
app/lib/src/transport/connection_config.dart      # sealed ConnectionConfig + Agent/Tls variants
app/lib/src/state/providers.dart                  # + credentialStoreProvider
app/lib/src/ui/connection_screen.dart             # transport-type selector (refactor)
app/lib/src/ui/connect/agent_form.dart            # extracted agent form
app/lib/src/ui/connect/tls_form.dart              # TLS form
app/test/fixtures/client-cert.pem, client-key.pem # committed self-signed test material
app/pubspec.yaml                                   # + flutter_secure_storage
app/test/...                                        # mirrors the above
```

---

## Task 1: Credential storage

**Files:**
- Modify: `app/pubspec.yaml` (add `flutter_secure_storage`)
- Create: `app/lib/src/storage/credential_store.dart`
- Test: `app/test/storage/credential_store_test.dart`

**Interfaces:**
- Produces:
  - `class TlsCredentials { final String host; final int port; final String clientCertPem, clientKeyPem; final String? caPem; final bool insecure; const TlsCredentials({...}); Map<String,dynamic> toJson(); factory TlsCredentials.fromJson(Map); }`
  - `abstract class CredentialStore { Future<void> saveTls(TlsCredentials); Future<TlsCredentials?> loadTls(); Future<void> clearTls(); }`
  - `class InMemoryCredentialStore implements CredentialStore` (tests), `class SecureCredentialStore implements CredentialStore` (real).

- [ ] **Step 1: Add the dependency**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter pub add flutter_secure_storage`
Expected: `pubspec.yaml` gains `flutter_secure_storage:` and `pub get` succeeds.

- [ ] **Step 2: Write the failing test**

Create `app/test/storage/credential_store_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';

void main() {
  test('save/load round-trips all fields', () async {
    final store = InMemoryCredentialStore();
    const creds = TlsCredentials(
      host: '10.0.0.5', port: 2376,
      clientCertPem: 'CERT', clientKeyPem: 'KEY', caPem: 'CA', insecure: true,
    );
    await store.saveTls(creds);
    final loaded = await store.loadTls();
    expect(loaded, isNotNull);
    expect(loaded!.host, '10.0.0.5');
    expect(loaded.port, 2376);
    expect(loaded.clientCertPem, 'CERT');
    expect(loaded.clientKeyPem, 'KEY');
    expect(loaded.caPem, 'CA');
    expect(loaded.insecure, true);
  });

  test('null CA and default insecure round-trip', () async {
    final store = InMemoryCredentialStore();
    await store.saveTls(const TlsCredentials(host: 'h', port: 2376, clientCertPem: 'c', clientKeyPem: 'k'));
    final loaded = await store.loadTls();
    expect(loaded!.caPem, isNull);
    expect(loaded.insecure, false);
  });

  test('loadTls is null before any save; clearTls empties', () async {
    final store = InMemoryCredentialStore();
    expect(await store.loadTls(), isNull);
    await store.saveTls(const TlsCredentials(host: 'h', port: 1, clientCertPem: 'c', clientKeyPem: 'k'));
    expect(await store.loadTls(), isNotNull);
    await store.clearTls();
    expect(await store.loadTls(), isNull);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/storage/credential_store_test.dart`
Expected: FAIL — types undefined.

- [ ] **Step 4: Write the implementation**

Create `app/lib/src/storage/credential_store.dart`:
```dart
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TlsCredentials {
  final String host;
  final int port;
  final String clientCertPem;
  final String clientKeyPem;
  final String? caPem;
  final bool insecure;

  const TlsCredentials({
    required this.host,
    required this.port,
    required this.clientCertPem,
    required this.clientKeyPem,
    this.caPem,
    this.insecure = false,
  });

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'clientCertPem': clientCertPem,
        'clientKeyPem': clientKeyPem,
        'caPem': caPem,
        'insecure': insecure,
      };

  factory TlsCredentials.fromJson(Map<String, dynamic> json) => TlsCredentials(
        host: json['host'] as String,
        port: (json['port'] as num).toInt(),
        clientCertPem: json['clientCertPem'] as String,
        clientKeyPem: json['clientKeyPem'] as String,
        caPem: json['caPem'] as String?,
        insecure: json['insecure'] as bool? ?? false,
      );
}

abstract class CredentialStore {
  Future<void> saveTls(TlsCredentials creds);
  Future<TlsCredentials?> loadTls();
  Future<void> clearTls();
}

/// In-memory store for tests (no platform channels).
class InMemoryCredentialStore implements CredentialStore {
  String? _json;
  @override
  Future<void> saveTls(TlsCredentials creds) async => _json = jsonEncode(creds.toJson());
  @override
  Future<TlsCredentials?> loadTls() async =>
      _json == null ? null : TlsCredentials.fromJson(jsonDecode(_json!) as Map<String, dynamic>);
  @override
  Future<void> clearTls() async => _json = null;
}

/// Keychain/Keystore-backed store for the running app.
class SecureCredentialStore implements CredentialStore {
  static const _key = 'tls_last';
  final FlutterSecureStorage _storage;
  SecureCredentialStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<void> saveTls(TlsCredentials creds) => _storage.write(key: _key, value: jsonEncode(creds.toJson()));

  @override
  Future<TlsCredentials?> loadTls() async {
    final v = await _storage.read(key: _key);
    return v == null ? null : TlsCredentials.fromJson(jsonDecode(v) as Map<String, dynamic>);
  }

  @override
  Future<void> clearTls() => _storage.delete(key: _key);
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/storage/credential_store_test.dart && flutter analyze`
Expected: PASS; analyzer clean.

- [ ] **Step 6: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/src/storage/credential_store.dart app/test/storage/credential_store_test.dart
git commit -m "feat(app): CredentialStore + flutter_secure_storage for TLS creds"
```

---

## Task 2: TLS security builder

**Files:**
- Create: `app/lib/src/transport/tls_security.dart`
- Create (generated, committed): `app/test/fixtures/client-cert.pem`, `app/test/fixtures/client-key.pem`
- Test: `app/test/transport/tls_security_test.dart`

**Interfaces:**
- Produces:
  - `class TlsConfigException implements Exception { final String message; const TlsConfigException(this.message); }`
  - `HttpClient buildTlsHttpClient({required List<int> clientCertPem, required List<int> clientKeyPem, List<int>? caPem, bool insecure = false, String? keyPassword})`

- [ ] **Step 1: Generate committed test fixtures**

Run (Git Bash; `MSYS_NO_PATHCONV=1` stops the subject being path-mangled):
```bash
mkdir -p app/test/fixtures
MSYS_NO_PATHCONV=1 openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout app/test/fixtures/client-key.pem \
  -out app/test/fixtures/client-cert.pem \
  -subj "/CN=docker-mobile-test"
```
Expected: a valid self-signed cert + unencrypted key. Verify: `head -1 app/test/fixtures/client-cert.pem` shows `-----BEGIN CERTIFICATE-----`.

- [ ] **Step 2: Write the failing test**

Create `app/test/transport/tls_security_test.dart`:
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/tls_security.dart';

void main() {
  final cert = File('test/fixtures/client-cert.pem').readAsBytesSync();
  final key = File('test/fixtures/client-key.pem').readAsBytesSync();

  test('builds an HttpClient from valid client cert + key', () {
    final client = buildTlsHttpClient(clientCertPem: cert, clientKeyPem: key);
    expect(client, isA<HttpClient>());
    client.close(force: true);
  });

  test('accepts a CA and keeps verification on by default', () {
    final client = buildTlsHttpClient(clientCertPem: cert, clientKeyPem: key, caPem: cert);
    expect(client.badCertificateCallback, isNull); // secure: no skip callback
    client.close(force: true);
  });

  test('insecure:true installs a permissive badCertificateCallback', () {
    final client = buildTlsHttpClient(clientCertPem: cert, clientKeyPem: key, insecure: true);
    expect(client.badCertificateCallback, isNotNull);
    expect(client.badCertificateCallback!(/*cert*/ _AnyCert(), 'host', 2376), isTrue);
    client.close(force: true);
  });

  test('malformed PEM throws TlsConfigException', () {
    expect(
      () => buildTlsHttpClient(clientCertPem: [1, 2, 3], clientKeyPem: [4, 5, 6]),
      throwsA(isA<TlsConfigException>()),
    );
  });
}

class _AnyCert implements X509Certificate {
  @override
  noSuchMethod(Invocation invocation) => null;
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/tls_security_test.dart`
Expected: FAIL — `buildTlsHttpClient`/`TlsConfigException` undefined.

- [ ] **Step 4: Write the implementation**

Create `app/lib/src/transport/tls_security.dart`:
```dart
import 'dart:io';

class TlsConfigException implements Exception {
  final String message;
  const TlsConfigException(this.message);
  @override
  String toString() => 'TlsConfigException: $message';
}

/// Builds an [HttpClient] for mutual-TLS to a Docker daemon. The client cert +
/// key authenticate us; [caPem], when given, pins the server to that CA.
/// [insecure] skips server verification (off by default).
HttpClient buildTlsHttpClient({
  required List<int> clientCertPem,
  required List<int> clientKeyPem,
  List<int>? caPem,
  bool insecure = false,
  String? keyPassword,
}) {
  final SecurityContext ctx;
  try {
    ctx = SecurityContext(withTrustedRoots: false);
    ctx.useCertificateChainBytes(clientCertPem);
    ctx.usePrivateKeyBytes(clientKeyPem, password: keyPassword);
    if (caPem != null) ctx.setTrustedCertificatesBytes(caPem);
  } on TlsException catch (e) {
    throw TlsConfigException(e.message);
  } on ArgumentError catch (e) {
    throw TlsConfigException(e.toString());
  }
  final client = HttpClient(context: ctx);
  if (insecure) {
    client.badCertificateCallback = (cert, host, port) => true;
  }
  return client;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/tls_security_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/transport/tls_security.dart app/test/transport/tls_security_test.dart app/test/fixtures/client-cert.pem app/test/fixtures/client-key.pem
git commit -m "feat(app): TLS SecurityContext builder (CA pin + insecure opt-in)"
```

---

## Task 3: TlsTransport

**Files:**
- Create: `app/lib/src/transport/tls_transport.dart`
- Test: `app/test/transport/tls_transport_test.dart`

**Interfaces:**
- Consumes: `Transport`/`ExecChannel`/`TransportException` (transport.dart), `tls_security.dart` (for `hijackExec` building only).
- Produces:
  - `class TlsTransport implements Transport` — constructor `TlsTransport({required Uri baseUri, required http.Client client, Future<ExecChannel> Function(String execId, int cols, int rows)? execOpener})`.
  - `class SocketExecChannel implements ExecChannel` — `SocketExecChannel({required Stream<List<int>> input, required void Function(List<int>) onSend, required Future<void> Function() onClose})`.
  - `Future<ExecChannel> hijackExec(HttpClient httpClient, Uri baseUri, String execId, int cols, int rows)`.

- [ ] **Step 1: Write the failing test**

Create `app/test/transport/tls_transport_test.dart`:
```dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/transport/tls_transport.dart';

/// Records the last request and returns a programmed streamed response.
class _FakeClient extends http.BaseClient {
  http.BaseRequest? last;
  String? lastBody;
  int status = 200;
  List<int> respBody = const [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    last = request;
    if (request is http.Request) lastBody = request.body;
    return http.StreamedResponse(Stream.value(respBody), status, request: request);
  }
}

void main() {
  final base = Uri.parse('https://10.0.0.5:2376');

  test('get builds the URI with no Authorization header', () async {
    final c = _FakeClient()..respBody = utf8.encode('[]');
    final t = TlsTransport(baseUri: base, client: c);
    await t.get('/containers/json', query: {'all': 'true'});
    expect(c.last!.method, 'GET');
    expect(c.last!.url.toString(), 'https://10.0.0.5:2376/containers/json?all=true');
    expect(c.last!.headers.containsKey('Authorization'), isFalse);
  });

  test('post JSON-encodes a map body and sets Content-Type, no auth', () async {
    final c = _FakeClient();
    final t = TlsTransport(baseUri: base, client: c);
    await t.post('/containers/x/exec', body: {'Cmd': ['sh']});
    expect(c.last!.method, 'POST');
    expect(c.lastBody, '{"Cmd":["sh"]}');
    expect((c.last!.headers['content-type'] ?? '').contains('application/json'), isTrue);
    expect(c.last!.headers.containsKey('Authorization'), isFalse);
  });

  test('delete builds the URI with query', () async {
    final c = _FakeClient();
    final t = TlsTransport(baseUri: base, client: c);
    await t.delete('/containers/x', query: {'force': 'true'});
    expect(c.last!.method, 'DELETE');
    expect(c.last!.url.query, 'force=true');
  });

  test('stream yields the response bytes and is 200-gated', () async {
    final c = _FakeClient()..respBody = utf8.encode('chunk');
    final t = TlsTransport(baseUri: base, client: c);
    final bytes = await t.stream('/containers/x/logs').first;
    expect(utf8.decode(bytes), 'chunk');
  });

  test('stream surfaces a non-200 as TransportException', () async {
    final c = _FakeClient()..status = 404..respBody = utf8.encode('no such container');
    final t = TlsTransport(baseUri: base, client: c);
    expect(t.stream('/containers/x/logs').first, throwsA(isA<TransportException>()));
  });

  test('execAttach delegates to the injected opener', () async {
    final channel = SocketExecChannel(input: const Stream.empty(), onSend: (_) {}, onClose: () async {});
    var captured = <Object>[];
    final t = TlsTransport(
      baseUri: base,
      client: _FakeClient(),
      execOpener: (id, cols, rows) async { captured = [id, cols, rows]; return channel; },
    );
    final ch = await t.execAttach('exec123', cols: 80, rows: 24);
    expect(identical(ch, channel), isTrue);
    expect(captured, ['exec123', 80, 24]);
  });

  test('SocketExecChannel forwards send, maps output, and closes once', () async {
    final sent = <List<int>>[];
    var closes = 0;
    final ch = SocketExecChannel(
      input: Stream.value(utf8.encode('out')),
      onSend: sent.add,
      onClose: () async { closes++; },
    );
    expect(utf8.decode(await ch.output.first), 'out');
    ch.send(utf8.encode('in'));
    expect(utf8.decode(sent.single), 'in');
    await ch.close();
    await ch.close(); // idempotent
    expect(closes, 1);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/tls_transport_test.dart`
Expected: FAIL — `TlsTransport`/`SocketExecChannel` undefined.

- [ ] **Step 3: Write the implementation**

Create `app/lib/src/transport/tls_transport.dart`:
```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'transport.dart';

/// Direct mutual-TLS transport to a Docker daemon (no agent, no bearer token).
class TlsTransport implements Transport {
  final Uri baseUri;
  final http.Client _client;
  final Future<ExecChannel> Function(String execId, int cols, int rows)? _execOpener;

  TlsTransport({
    required this.baseUri,
    required http.Client client,
    Future<ExecChannel> Function(String execId, int cols, int rows)? execOpener,
  })  : _client = client,
        _execOpener = execOpener;

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) =>
      _client.get(baseUri.replace(path: path, queryParameters: query));

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      _client.delete(baseUri.replace(path: path, queryParameters: query));

  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    final h = <String, String>{...?headers};
    String? encoded;
    if (body != null) {
      encoded = body is String ? body : jsonEncode(body);
      h['Content-Type'] = 'application/json';
    }
    return _client.post(uri, headers: h, body: encoded);
  }

  Stream<List<int>> _openStream(http.Request request) {
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    controller.onListen = () async {
      try {
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          controller.addError(TransportException(response.statusCode, body));
          await controller.close();
          return;
        }
        sub = response.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: () => controller.close(),
          cancelOnError: true,
        );
      } catch (e) {
        controller.addError(e);
        await controller.close();
      }
    };
    // Cancel just stops reading; the shared client stays alive for other calls.
    controller.onCancel = () async => sub?.cancel();
    return controller.stream;
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) =>
      _openStream(http.Request('GET', baseUri.replace(path: path, queryParameters: query)));

  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) {
    final request = http.Request('POST', baseUri.replace(path: path, queryParameters: query));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = body is String ? body : jsonEncode(body);
    }
    return _openStream(request);
  }

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) {
    final opener = _execOpener;
    if (opener == null) {
      throw UnsupportedError('exec requires a hijack opener (use ConnectionConfig to build a live TlsTransport)');
    }
    return opener(execId, cols, rows);
  }
}

/// Wraps a raw duplex (a hijacked socket in production, in-memory in tests).
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

/// Hijacks `POST /exec/{id}/start` and returns the detached socket as a duplex
/// channel. Exercised by the manual smoke test (real socket; not unit-tested).
Future<ExecChannel> hijackExec(HttpClient httpClient, Uri baseUri, String execId, int cols, int rows) async {
  final req = await httpClient.openUrl('POST', baseUri.replace(path: '/exec/$execId/start'));
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  req.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
  req.headers.set('Upgrade', 'tcp');
  req.add(utf8.encode(jsonEncode({'Detach': false, 'Tty': true})));
  final resp = await req.close();
  final socket = await resp.detachSocket();
  return SocketExecChannel(
    input: socket,
    onSend: socket.add,
    onClose: () async {
      await socket.flush();
      socket.destroy();
    },
  );
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/tls_transport_test.dart && flutter analyze`
Expected: PASS (7 tests); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/transport/tls_transport.dart app/test/transport/tls_transport_test.dart
git commit -m "feat(app): TlsTransport (HTTP surface + cancelable stream + exec hijack)"
```

---

## Task 4: ConnectionConfig

**Files:**
- Create: `app/lib/src/transport/connection_config.dart`
- Test: `app/test/transport/connection_config_test.dart`

**Interfaces:**
- Consumes: `AgentTransport`, `TlsTransport`/`hijackExec`, `buildTlsHttpClient`/`TlsConfigException`, `Transport`.
- Produces:
  - `sealed class ConnectionConfig { Transport build(); }`
  - `class AgentConnectionConfig extends ConnectionConfig { AgentConnectionConfig({required Uri baseUri, required String token}); }`
  - `class TlsConnectionConfig extends ConnectionConfig { TlsConnectionConfig({required String host, required int port, required String clientCertPem, required String clientKeyPem, String? caPem, bool insecure = false}); }`

- [ ] **Step 1: Write the failing test**

Create `app/test/transport/connection_config_test.dart`:
```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';
import 'package:docker_mobile/src/transport/tls_transport.dart';
import 'package:docker_mobile/src/transport/tls_security.dart';
import 'package:docker_mobile/src/transport/connection_config.dart';

void main() {
  final cert = File('test/fixtures/client-cert.pem').readAsStringSync();
  final key = File('test/fixtures/client-key.pem').readAsStringSync();

  test('AgentConnectionConfig builds an AgentTransport', () {
    final t = AgentConnectionConfig(baseUri: Uri.parse('http://h:8080'), token: 'tok').build();
    expect(t, isA<AgentTransport>());
  });

  test('TlsConnectionConfig builds a TlsTransport from valid PEM', () {
    final t = TlsConnectionConfig(
      host: '10.0.0.5', port: 2376, clientCertPem: cert, clientKeyPem: key,
    ).build();
    expect(t, isA<TlsTransport>());
  });

  test('TlsConnectionConfig surfaces malformed PEM as TlsConfigException', () {
    expect(
      () => TlsConnectionConfig(host: 'h', port: 2376, clientCertPem: 'nope', clientKeyPem: 'nope').build(),
      throwsA(isA<TlsConfigException>()),
    );
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/connection_config_test.dart`
Expected: FAIL — config types undefined.

- [ ] **Step 3: Write the implementation**

Create `app/lib/src/transport/connection_config.dart`:
```dart
import 'dart:convert';

import 'package:http/io_client.dart';

import 'agent_transport.dart';
import 'tls_security.dart';
import 'tls_transport.dart';
import 'transport.dart';

/// A connection the user configured; [build] produces a live [Transport].
sealed class ConnectionConfig {
  Transport build();
}

class AgentConnectionConfig extends ConnectionConfig {
  final Uri baseUri;
  final String token;
  AgentConnectionConfig({required this.baseUri, required this.token});

  @override
  Transport build() => AgentTransport(baseUri: baseUri, token: token);
}

class TlsConnectionConfig extends ConnectionConfig {
  final String host;
  final int port;
  final String clientCertPem;
  final String clientKeyPem;
  final String? caPem;
  final bool insecure;

  TlsConnectionConfig({
    required this.host,
    required this.port,
    required this.clientCertPem,
    required this.clientKeyPem,
    this.caPem,
    this.insecure = false,
  });

  @override
  Transport build() {
    final httpClient = buildTlsHttpClient(
      clientCertPem: utf8.encode(clientCertPem),
      clientKeyPem: utf8.encode(clientKeyPem),
      caPem: caPem == null ? null : utf8.encode(caPem!),
      insecure: insecure,
    );
    final baseUri = Uri(scheme: 'https', host: host, port: port);
    return TlsTransport(
      baseUri: baseUri,
      client: IOClient(httpClient),
      execOpener: (id, cols, rows) => hijackExec(httpClient, baseUri, id, cols, rows),
    );
  }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/connection_config_test.dart && flutter analyze`
Expected: PASS (3 tests); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/transport/connection_config.dart app/test/transport/connection_config_test.dart
git commit -m "feat(app): ConnectionConfig sealed type (Agent/Tls -> Transport)"
```

---

## Task 5: Connect form (transport-type selector + TLS form)

**Files:**
- Modify: `app/lib/src/state/providers.dart` (add `credentialStoreProvider`)
- Modify: `app/lib/src/ui/connection_screen.dart` (type selector)
- Create: `app/lib/src/ui/connect/agent_form.dart`, `app/lib/src/ui/connect/tls_form.dart`
- Modify: `docs/MANUAL-SMOKE-TEST.md` (add TCP+TLS section)
- Test: `app/test/ui/connection_screen_test.dart`

**Interfaces:**
- Consumes: `ConnectionConfig` types (Task 4), `CredentialStore`/`TlsCredentials` (Task 1), `TlsConfigException` (Task 2), `transportProvider` (existing).
- Produces: `credentialStoreProvider`; refactored `ConnectionScreen`; `AgentForm`; `TlsForm`.

- [ ] **Step 1: Add the credential-store provider**

In `app/lib/src/state/providers.dart`, add `import '../storage/credential_store.dart';` and:
```dart
/// The secure credential store (overridden with an in-memory fake in tests).
final credentialStoreProvider = Provider<CredentialStore>((ref) => SecureCredentialStore());
```

- [ ] **Step 2: Write the failing widget test**

Create `app/test/ui/connection_screen_test.dart`:
```dart
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/transport/tls_transport.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';

Widget _wrap(CredentialStore store) => ProviderScope(
      overrides: [credentialStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: ConnectionScreen()),
    );

void main() {
  final cert = File('test/fixtures/client-cert.pem').readAsStringSync();
  final key = File('test/fixtures/client-key.pem').readAsStringSync();

  testWidgets('selecting TCP+TLS reveals the PEM fields', (tester) async {
    await tester.pumpWidget(_wrap(InMemoryCredentialStore()));
    expect(find.text('Client certificate (PEM)'), findsNothing); // agent tab first
    await tester.tap(find.text('TCP+TLS'));
    await tester.pumpAndSettle();
    expect(find.text('Client certificate (PEM)'), findsOneWidget);
    expect(find.text('Client key (PEM)'), findsOneWidget);
  });

  testWidgets('invalid host blocks connect', (tester) async {
    final store = InMemoryCredentialStore();
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [credentialStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: ConnectionScreen()),
    ));
    container = ProviderScope.containerOf(tester.element(find.byType(ConnectionScreen)));
    await tester.tap(find.text('TCP+TLS'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Client certificate (PEM)'), cert);
    await tester.enterText(find.widgetWithText(TextField, 'Client key (PEM)'), key);
    // host left empty
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump();
    expect(find.textContaining('valid host'), findsOneWidget);
    expect(container.read(transportProvider), isNull);
  });

  testWidgets('valid TLS submit sets a TlsTransport and saves creds', (tester) async {
    final store = InMemoryCredentialStore();
    await tester.pumpWidget(_wrap(store));
    final container = ProviderScope.containerOf(tester.element(find.byType(ConnectionScreen)));
    await tester.tap(find.text('TCP+TLS'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '127.0.0.1');
    await tester.enterText(find.widgetWithText(TextField, 'Client certificate (PEM)'), cert);
    await tester.enterText(find.widgetWithText(TextField, 'Client key (PEM)'), key);
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump(); // one frame; do NOT settle (HomeScreen would hit the network)

    expect(container.read(transportProvider), isA<TlsTransport>());
    final saved = await store.loadTls();
    expect(saved, isNotNull);
    expect(saved!.host, '127.0.0.1');
    expect(saved.clientCertPem, cert);
  });

  testWidgets('prefills the form from stored credentials', (tester) async {
    final store = InMemoryCredentialStore();
    await store.saveTls(TlsCredentials(host: '192.168.1.50', port: 2376, clientCertPem: cert, clientKeyPem: key));
    await tester.pumpWidget(_wrap(store));
    await tester.tap(find.text('TCP+TLS'));
    await tester.pumpAndSettle(); // lets initState's async prefill complete
    expect(find.text('192.168.1.50'), findsOneWidget);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/connection_screen_test.dart`
Expected: FAIL — `AgentForm`/`TlsForm`/new `ConnectionScreen` not present.

- [ ] **Step 4: Extract the agent form**

Create `app/lib/src/ui/connect/agent_form.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../transport/connection_config.dart';
import '../home_screen.dart';

class AgentForm extends ConsumerStatefulWidget {
  const AgentForm({super.key});
  @override
  ConsumerState<AgentForm> createState() => _AgentFormState();
}

class _AgentFormState extends ConsumerState<AgentForm> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8080');
  final _token = TextEditingController();
  bool _useTls = false;

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  void _connect() {
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a valid host and port (1-65535).')),
      );
      return;
    }
    final baseUri = Uri(scheme: _useTls ? 'https' : 'http', host: host, port: port);
    ref.read(transportProvider.notifier).state =
        AgentConnectionConfig(baseUri: baseUri, token: _token.text).build();
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host / IP')),
        TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
        TextField(controller: _token, decoration: const InputDecoration(labelText: 'Token'), obscureText: true),
        SwitchListTile(title: const Text('Use TLS (https)'), value: _useTls, onChanged: (v) => setState(() => _useTls = v)),
        const SizedBox(height: 16),
        FilledButton(onPressed: _connect, child: const Text('Connect')),
      ],
    );
  }
}
```

- [ ] **Step 5: Write the TLS form**

Create `app/lib/src/ui/connect/tls_form.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/providers.dart';
import '../../storage/credential_store.dart';
import '../../transport/connection_config.dart';
import '../../transport/tls_security.dart';
import '../../transport/transport.dart';
import '../home_screen.dart';

class TlsForm extends ConsumerStatefulWidget {
  const TlsForm({super.key});
  @override
  ConsumerState<TlsForm> createState() => _TlsFormState();
}

class _TlsFormState extends ConsumerState<TlsForm> {
  final _host = TextEditingController();
  final _port = TextEditingController(text: '2376');
  final _cert = TextEditingController();
  final _key = TextEditingController();
  final _ca = TextEditingController();
  bool _insecure = false;

  @override
  void initState() {
    super.initState();
    _prefill();
  }

  Future<void> _prefill() async {
    final creds = await ref.read(credentialStoreProvider).loadTls();
    if (creds == null || !mounted) return;
    setState(() {
      _host.text = creds.host;
      _port.text = '${creds.port}';
      _cert.text = creds.clientCertPem;
      _key.text = creds.clientKeyPem;
      _ca.text = creds.caPem ?? '';
      _insecure = creds.insecure;
    });
  }

  @override
  void dispose() {
    _host.dispose();
    _port.dispose();
    _cert.dispose();
    _key.dispose();
    _ca.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (host.isEmpty || port == null || port < 1 || port > 65535) {
      messenger.showSnackBar(const SnackBar(content: Text('Enter a valid host and port (1-65535).')));
      return;
    }
    if (_cert.text.trim().isEmpty || _key.text.trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(content: Text('Client certificate and key are required.')));
      return;
    }
    final caText = _ca.text.trim();
    final config = TlsConnectionConfig(
      host: host,
      port: port,
      clientCertPem: _cert.text,
      clientKeyPem: _key.text,
      caPem: caText.isEmpty ? null : caText,
      insecure: _insecure,
    );
    final Transport transport;
    try {
      transport = config.build();
    } on TlsConfigException catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Invalid certificate: ${e.message}')));
      return;
    }
    ref.read(transportProvider.notifier).state = transport;
    await ref.read(credentialStoreProvider).saveTls(TlsCredentials(
          host: host,
          port: port,
          clientCertPem: _cert.text,
          clientKeyPem: _key.text,
          caPem: caText.isEmpty ? null : caText,
          insecure: _insecure,
        ));
    navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host / IP')),
        TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
        TextField(controller: _cert, decoration: const InputDecoration(labelText: 'Client certificate (PEM)'), maxLines: 4),
        TextField(controller: _key, decoration: const InputDecoration(labelText: 'Client key (PEM)'), maxLines: 4),
        TextField(controller: _ca, decoration: const InputDecoration(labelText: 'CA certificate (PEM, optional)'), maxLines: 4),
        SwitchListTile(
          title: const Text('Allow insecure (skip server verification)'),
          value: _insecure,
          onChanged: (v) => setState(() => _insecure = v),
        ),
        const SizedBox(height: 16),
        FilledButton(onPressed: _connect, child: const Text('Connect')),
      ],
    );
  }
}
```

- [ ] **Step 6: Refactor ConnectionScreen into a type selector**

Replace `app/lib/src/ui/connection_screen.dart` with:
```dart
import 'package:flutter/material.dart';

import 'connect/agent_form.dart';
import 'connect/tls_form.dart';

enum _TransportType { agent, tls }

class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  _TransportType _type = _TransportType.agent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            SegmentedButton<_TransportType>(
              segments: const [
                ButtonSegment(value: _TransportType.agent, label: Text('Agent'), icon: Icon(Icons.dns)),
                ButtonSegment(value: _TransportType.tls, label: Text('TCP+TLS'), icon: Icon(Icons.lock)),
              ],
              selected: {_type},
              onSelectionChanged: (s) => setState(() => _type = s.first),
            ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: _type == _TransportType.agent ? const AgentForm() : const TlsForm(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 7: Run the connection-screen test + the full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/connection_screen_test.dart && flutter analyze && flutter test`
Expected: the new test passes; analyzer clean; **all** app tests pass (existing `widget_test.dart` "boots to the connection screen" still green — the agent tab is default and `AgentForm` keeps the same fields; it must not touch secure storage on boot).

- [ ] **Step 8: Document the manual smoke test**

In `docs/MANUAL-SMOKE-TEST.md`, append a TCP+TLS section:
```markdown
## TCP+TLS (mTLS) — Phase 1D-1

Real socket + exec hijack path (not covered by unit tests).

1. Generate a CA + server cert + client cert (see Docker's "Protect the Docker daemon socket" guide), then run dockerd with TLS verification:
   `dockerd --tlsverify --tlscacert=ca.pem --tlscert=server-cert.pem --tlskey=server-key.pem -H=0.0.0.0:2376`
2. In the app: Connect → **TCP+TLS**. Enter host, port `2376`, and paste `client-cert.pem`, `client-key.pem`, and `ca.pem` into the CA field. Leave **Allow insecure** OFF.
3. Verify: the container list loads; open a container → **Logs** stream live; **Exec** opens an interactive shell (the hijack path); **System** dashboard loads.
4. Negative check: with a wrong/empty CA and **Allow insecure** OFF, the connection fails the TLS handshake; turning **Allow insecure** ON connects (documented as insecure — MITM-vulnerable).
```

- [ ] **Step 9: Commit**

```bash
git add app/lib/src/state/providers.dart app/lib/src/ui/connection_screen.dart app/lib/src/ui/connect/agent_form.dart app/lib/src/ui/connect/tls_form.dart app/test/ui/connection_screen_test.dart docs/MANUAL-SMOKE-TEST.md
git commit -m "feat(app): connect screen transport selector + TLS form"
```

---

## Self-Review

**1. Spec coverage:**
- `TlsTransport` (get/stream/post/execAttach/delete/postStream, no bearer) → Task 3. ✓
- `tls_security.buildTlsHttpClient` (CA pin + insecure + TlsConfigException) → Task 2. ✓
- Client-side exec hijack (`/exec/{id}/start` Upgrade → detachSocket → ExecChannel) → Task 3 (`hijackExec` + `SocketExecChannel`). ✓
- `CredentialStore` (interface + secure + in-memory) → Task 1. ✓
- `ConnectionConfig` sealed (Agent/Tls build) → Task 4. ✓
- Connect screen type selector + `TlsForm` + `credentialStoreProvider` + prefill/save → Task 5. ✓
- Default port 2376; insecure toggle off by default; paste-PEM; one-slot persistence → Tasks 1/5. ✓
- Manual smoke (real socket/hijack) → Task 5 Step 8. ✓
- Out of scope (SSH, profiles, file-picker, agent changes) → absent. ✓
- `flutter_secure_storage` dep → Task 1. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete. Fixtures are generated by an exact openssl command and committed.

**3. Type consistency:** `buildTlsHttpClient({clientCertPem, clientKeyPem, caPem?, insecure, keyPassword})` (Task 2) is called identically in Task 4. `TlsTransport({baseUri, client, execOpener})` + `SocketExecChannel({input, onSend, onClose})` + `hijackExec(httpClient, baseUri, execId, cols, rows)` (Task 3) are used identically in Task 4 (`hijackExec`) and the Task 3 tests. `TlsCredentials({host, port, clientCertPem, clientKeyPem, caPem?, insecure})` (Task 1) is constructed identically in Task 5. `AgentConnectionConfig({baseUri, token})` / `TlsConnectionConfig({host, port, clientCertPem, clientKeyPem, caPem?, insecure})` (Task 4) are constructed identically in Task 5. `credentialStoreProvider` (Task 5 Step 1) overridden in the Task 5 tests. `transportProvider` holds the `Transport` from `config.build()`. ✓
