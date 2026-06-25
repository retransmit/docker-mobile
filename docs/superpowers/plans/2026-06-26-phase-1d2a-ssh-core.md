# Phase 1D-2a — SSH Transport Core — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The plumbing to reach a Docker daemon over SSH — `docker system dial-stdio` + a byte-tested HTTP-over-stream client + SSH credential storage + TOFU host-key policy.

**Architecture:** An SSH exec session running `docker system dial-stdio` (via `dartssh2`) yields a raw duplex byte-stream to the remote `/var/run/docker.sock`; a hand-rolled minimal HTTP/1.1 client serializes requests and frames responses over it. The live SSH calls sit behind a thin `SshDaemonConnection` seam; the HTTP parser, credential store, and host-key TOFU decision are pure and fully unit-tested.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `dartssh2` (new), `crypto` (new), dart:async/convert.

## Global Constraints

- **Reach mechanism:** SSH exec `docker system dial-stdio` (NOT port-forward). One dial-stdio channel per HTTP request; no pooling/keep-alive (YAGNI).
- **Auth:** private key (PEM + optional passphrase) OR username+password.
- **Host key:** TOFU — first connect captures+pins the SHA-256 fingerprint; later connects must match (verdict `mismatch` otherwise). No accept-any in this slice.
- **HTTP is hand-rolled** over the duplex (no dart:io `HttpClient`); the parser is pure and byte-tested.
- **Scope:** app-only; no Go agent changes. This slice is CORE only — NO `SshTransport`/`Transport` impl, NO streaming wiring into the app, NO exec hijack, NO `SshConnectionConfig`, NO SSH form (all D2b). No multi-host map (D3).
- **Testing seam:** the live `dartssh2` connect/dial-stdio (`SshDaemonConnection.open`, `sshDaemonVersion`) is manual-smoke only; everything above the seam is unit-tested. Tests never open a real SSH connection.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/storage/credential_store.dart            # + SshAuthMethod + SshCredentials + saveSsh/loadSsh/clearSsh
app/lib/src/transport/ssh/host_key.dart              # fingerprintSha256 + verifyHostKey (pure)
app/lib/src/transport/ssh/stream_http.dart           # writeHttpRequest + readHttpResponse + readBufferedResponse (pure)
app/lib/src/transport/ssh/ssh_connection.dart        # Duplex + SshDaemonConnection + dockerGet + sshDaemonVersion (dartssh2 seam)
app/pubspec.yaml                                      # + dartssh2 + crypto
docs/MANUAL-SMOKE-TEST.md                             # + SSH (dial-stdio) section
app/test/...                                           # mirrors the above (except the live seam)
```

---

## Task 1: SSH credentials in the store

**Files:**
- Modify: `app/lib/src/storage/credential_store.dart`
- Test: `app/test/storage/ssh_credentials_test.dart`

**Interfaces:**
- Produces:
  - `enum SshAuthMethod { password, key }`
  - `class SshCredentials { final String host; final int port; final String username; final SshAuthMethod authMethod; final String? password, privateKeyPem, passphrase, pinnedHostKey; const SshCredentials({...}); Map<String,dynamic> toJson(); factory SshCredentials.fromJson(Map); }`
  - `CredentialStore` gains `Future<void> saveSsh(SshCredentials)`, `Future<SshCredentials?> loadSsh()`, `Future<void> clearSsh()`.

- [ ] **Step 1: Write the failing test**

Create `app/test/storage/ssh_credentials_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';

void main() {
  test('key-auth creds round-trip', () async {
    final store = InMemoryCredentialStore();
    const creds = SshCredentials(
      host: 'h', port: 22, username: 'root', authMethod: SshAuthMethod.key,
      privateKeyPem: 'KEY', passphrase: 'pp', pinnedHostKey: 'FP',
    );
    await store.saveSsh(creds);
    final loaded = await store.loadSsh();
    expect(loaded!.host, 'h');
    expect(loaded.username, 'root');
    expect(loaded.authMethod, SshAuthMethod.key);
    expect(loaded.privateKeyPem, 'KEY');
    expect(loaded.passphrase, 'pp');
    expect(loaded.pinnedHostKey, 'FP');
    expect(loaded.password, isNull);
  });

  test('password-auth creds round-trip with null pin', () async {
    final store = InMemoryCredentialStore();
    await store.saveSsh(const SshCredentials(
      host: 'h', port: 2222, username: 'u', authMethod: SshAuthMethod.password, password: 'pw'));
    final loaded = await store.loadSsh();
    expect(loaded!.authMethod, SshAuthMethod.password);
    expect(loaded.password, 'pw');
    expect(loaded.pinnedHostKey, isNull);
    expect(loaded.privateKeyPem, isNull);
  });

  test('clearSsh empties only the ssh slot; tls slot is independent', () async {
    final store = InMemoryCredentialStore();
    await store.saveTls(const TlsCredentials(host: 't', port: 2376, clientCertPem: 'c', clientKeyPem: 'k'));
    await store.saveSsh(const SshCredentials(host: 'h', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'pw'));
    await store.clearSsh();
    expect(await store.loadSsh(), isNull);
    expect(await store.loadTls(), isNotNull); // unaffected
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/storage/ssh_credentials_test.dart`
Expected: FAIL — `SshCredentials`/`saveSsh` undefined.

- [ ] **Step 3: Add SSH credentials to the store**

In `app/lib/src/storage/credential_store.dart`, add the enum + class (place near `TlsCredentials`):
```dart
enum SshAuthMethod { password, key }

class SshCredentials {
  final String host;
  final int port;
  final String username;
  final SshAuthMethod authMethod;
  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
  final String? pinnedHostKey;

  const SshCredentials({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    this.password,
    this.privateKeyPem,
    this.passphrase,
    this.pinnedHostKey,
  });

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        'password': password,
        'privateKeyPem': privateKeyPem,
        'passphrase': passphrase,
        'pinnedHostKey': pinnedHostKey,
      };

  factory SshCredentials.fromJson(Map<String, dynamic> json) => SshCredentials(
        host: json['host'] as String,
        port: (json['port'] as num).toInt(),
        username: json['username'] as String,
        authMethod: SshAuthMethod.values.byName(json['authMethod'] as String),
        password: json['password'] as String?,
        privateKeyPem: json['privateKeyPem'] as String?,
        passphrase: json['passphrase'] as String?,
        pinnedHostKey: json['pinnedHostKey'] as String?,
      );
}
```
Add the three methods to the `abstract class CredentialStore`:
```dart
  Future<void> saveSsh(SshCredentials creds);
  Future<SshCredentials?> loadSsh();
  Future<void> clearSsh();
```
In `InMemoryCredentialStore`, add a second slot:
```dart
  String? _sshJson;
  @override
  Future<void> saveSsh(SshCredentials creds) async => _sshJson = jsonEncode(creds.toJson());
  @override
  Future<SshCredentials?> loadSsh() async =>
      _sshJson == null ? null : SshCredentials.fromJson(jsonDecode(_sshJson!) as Map<String, dynamic>);
  @override
  Future<void> clearSsh() async => _sshJson = null;
```
In `SecureCredentialStore`, add (with a new key constant `static const _sshKey = 'ssh_last';`):
```dart
  @override
  Future<void> saveSsh(SshCredentials creds) => _storage.write(key: _sshKey, value: jsonEncode(creds.toJson()));
  @override
  Future<SshCredentials?> loadSsh() async {
    final v = await _storage.read(key: _sshKey);
    return v == null ? null : SshCredentials.fromJson(jsonDecode(v) as Map<String, dynamic>);
  }
  @override
  Future<void> clearSsh() => _storage.delete(key: _sshKey);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/storage/ssh_credentials_test.dart && flutter analyze`
Expected: PASS (3 tests); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/storage/credential_store.dart app/test/storage/ssh_credentials_test.dart
git commit -m "feat(app): SshCredentials + CredentialStore ssh slot"
```

---

## Task 2: Host-key TOFU policy

**Files:**
- Modify: `app/pubspec.yaml` (add `crypto`)
- Create: `app/lib/src/transport/ssh/host_key.dart`
- Test: `app/test/transport/ssh/host_key_test.dart`

**Interfaces:**
- Produces:
  - `String fingerprintSha256(List<int> hostKeyBytes)` — base64(SHA-256(bytes)) without `=` padding.
  - `enum HostKeyVerdict { firstUse, match, mismatch }`
  - `HostKeyVerdict verifyHostKey(String? storedFingerprint, String presentedFingerprint)`

- [ ] **Step 1: Add the dependency**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter pub add crypto`
Expected: `pubspec.yaml` gains `crypto:`; `pub get` succeeds.

- [ ] **Step 2: Write the failing test**

Create `app/test/transport/ssh/host_key_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/ssh/host_key.dart';

void main() {
  test('fingerprint is deterministic, padding-free, and input-sensitive', () {
    final a = fingerprintSha256([1, 2, 3]);
    expect(fingerprintSha256([1, 2, 3]), a); // stable
    expect(fingerprintSha256([1, 2, 4]), isNot(a)); // differs by input
    expect(a.contains('='), isFalse); // no base64 padding
  });

  test('verifyHostKey verdicts', () {
    expect(verifyHostKey(null, 'x'), HostKeyVerdict.firstUse);
    expect(verifyHostKey('x', 'x'), HostKeyVerdict.match);
    expect(verifyHostKey('x', 'y'), HostKeyVerdict.mismatch);
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ssh/host_key_test.dart`
Expected: FAIL — `fingerprintSha256`/`verifyHostKey` undefined.

- [ ] **Step 4: Write the implementation**

Create `app/lib/src/transport/ssh/host_key.dart`:
```dart
import 'dart:convert';

import 'package:crypto/crypto.dart';

/// OpenSSH-style SHA-256 host-key fingerprint (base64, no padding), used to
/// pin a host on first use and compare on later connects.
String fingerprintSha256(List<int> hostKeyBytes) =>
    base64.encode(sha256.convert(hostKeyBytes).bytes).replaceAll('=', '');

enum HostKeyVerdict { firstUse, match, mismatch }

/// TOFU decision: no stored pin -> firstUse; equal -> match; else -> mismatch.
HostKeyVerdict verifyHostKey(String? storedFingerprint, String presentedFingerprint) {
  if (storedFingerprint == null) return HostKeyVerdict.firstUse;
  return storedFingerprint == presentedFingerprint ? HostKeyVerdict.match : HostKeyVerdict.mismatch;
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ssh/host_key_test.dart && flutter analyze`
Expected: PASS (2 tests); analyzer clean.

- [ ] **Step 6: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/src/transport/ssh/host_key.dart app/test/transport/ssh/host_key_test.dart
git commit -m "feat(app): SSH host-key SHA-256 fingerprint + TOFU verdict"
```

---

## Task 3: HTTP-over-stream client

**Files:**
- Create: `app/lib/src/transport/ssh/stream_http.dart`
- Test: `app/test/transport/ssh/stream_http_test.dart`

**Interfaces:**
- Produces:
  - `class StreamHttpException implements Exception { final String message; const StreamHttpException(this.message); }`
  - `void writeHttpRequest(void Function(List<int>) add, {required String method, required String path, Map<String,String>? headers, List<int>? body})`
  - `class StreamHttpResponse { final int statusCode; final Map<String,String> headers; final Stream<List<int>> body; bool get isUpgrade; }`
  - `Future<StreamHttpResponse> readHttpResponse(Stream<List<int>> input)`
  - `Future<({int statusCode, Map<String,String> headers, List<int> body})> readBufferedResponse(Stream<List<int>> input)`

- [ ] **Step 1: Write the failing test**

Create `app/test/transport/ssh/stream_http_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/ssh/stream_http.dart';

void main() {
  test('writeHttpRequest serializes a GET with no body', () {
    final out = <int>[];
    writeHttpRequest(out.addAll, method: 'GET', path: '/version');
    expect(ascii.decode(out), 'GET /version HTTP/1.1\r\nHost: docker\r\n\r\n');
  });

  test('writeHttpRequest serializes a POST with a JSON body + Content-Length', () {
    final out = <int>[];
    final body = utf8.encode('{"k":"v"}');
    writeHttpRequest(out.addAll, method: 'POST', path: '/x',
        headers: {'Content-Type': 'application/json'}, body: body);
    final text = ascii.decode(out);
    expect(text.startsWith('POST /x HTTP/1.1\r\nHost: docker\r\n'), isTrue);
    expect(text.contains('Content-Type: application/json\r\n'), isTrue);
    expect(text.contains('Content-Length: 9\r\n'), isTrue);
    expect(text.endsWith('\r\n\r\n{"k":"v"}'), isTrue);
  });

  test('readHttpResponse frames a Content-Length body', () async {
    final bytes = ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}');
    final resp = await readHttpResponse(Stream.value(bytes));
    expect(resp.statusCode, 200);
    expect(resp.isUpgrade, isFalse);
    final body = await resp.body.expand((c) => c).toList();
    expect(utf8.decode(body), '{}');
  });

  test('readHttpResponse de-chunks a body split across input events', () async {
    // chunk "hello" (5) split mid-data across two stream events, then terminator.
    final events = <List<int>>[
      ascii.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe'),
      ascii.encode('llo\r\n0\r\n\r\n'),
    ];
    final resp = await readHttpResponse(Stream.fromIterable(events));
    final body = await resp.body.expand((c) => c).toList();
    expect(utf8.decode(body), 'hello');
  });

  test('readHttpResponse detects a 101 upgrade and passes raw remainder', () async {
    final bytes = ascii.encode('HTTP/1.1 101 UPGRADED\r\nUpgrade: tcp\r\n\r\nRAW');
    final resp = await readHttpResponse(Stream.value(bytes));
    expect(resp.isUpgrade, isTrue);
    final raw = await resp.body.expand((c) => c).toList();
    expect(utf8.decode(raw), 'RAW');
  });

  test('readHttpResponse throws on a truncated head', () async {
    final bytes = ascii.encode('HTTP/1.1 200 OK\r\nContent-Le');
    expect(readHttpResponse(Stream.value(bytes)), throwsA(isA<StreamHttpException>()));
  });

  test('readBufferedResponse returns status, headers, and full body', () async {
    final bytes = ascii.encode('HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nno!');
    final r = await readBufferedResponse(Stream.value(bytes));
    expect(r.statusCode, 404);
    expect(r.headers['content-length'], '3');
    expect(utf8.decode(r.body), 'no!');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ssh/stream_http_test.dart`
Expected: FAIL — symbols undefined.

- [ ] **Step 3: Write the implementation**

Create `app/lib/src/transport/ssh/stream_http.dart`:
```dart
import 'dart:async';
import 'dart:convert';

class StreamHttpException implements Exception {
  final String message;
  const StreamHttpException(this.message);
  @override
  String toString() => 'StreamHttpException: $message';
}

/// Serializes an HTTP/1.1 request onto a duplex via [add]. Deterministic header
/// order (caller headers in insertion order, Content-Length last) for testing.
void writeHttpRequest(
  void Function(List<int>) add, {
  required String method,
  required String path,
  Map<String, String>? headers,
  List<int>? body,
}) {
  final sb = StringBuffer()
    ..write('$method $path HTTP/1.1\r\n')
    ..write('Host: docker\r\n');
  final h = <String, String>{...?headers};
  if (body != null) h['Content-Length'] = '${body.length}';
  h.forEach((k, v) => sb.write('$k: $v\r\n'));
  sb.write('\r\n');
  add(ascii.encode(sb.toString()));
  if (body != null && body.isNotEmpty) add(body);
}

class StreamHttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;
  StreamHttpResponse({required this.statusCode, required this.headers, required this.body});
  bool get isUpgrade => statusCode == 101;
}

/// Parses status line + headers, then frames the body by Content-Length /
/// chunked / 101-upgrade-raw / read-until-close.
Future<StreamHttpResponse> readHttpResponse(Stream<List<int>> input) async {
  final reader = _ByteReader(input);
  final head = await reader.readUntil(const [13, 10, 13, 10]); // CRLF CRLF
  if (head == null) throw const StreamHttpException('truncated response head');
  final lines = ascii.decode(head).split('\r\n')..removeWhere((l) => l.isEmpty);
  final parts = lines.first.split(' ');
  if (parts.length < 2) throw const StreamHttpException('bad status line');
  final statusCode = int.tryParse(parts[1]) ?? (throw const StreamHttpException('bad status code'));
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final i = line.indexOf(':');
    if (i > 0) headers[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
  }
  if (statusCode == 101) {
    return StreamHttpResponse(statusCode: 101, headers: headers, body: reader.remaining());
  }
  final te = headers['transfer-encoding'];
  if (te != null && te.toLowerCase().contains('chunked')) {
    return StreamHttpResponse(statusCode: statusCode, headers: headers, body: _dechunk(reader));
  }
  final cl = headers['content-length'];
  if (cl != null) {
    final n = int.tryParse(cl) ?? (throw const StreamHttpException('bad content-length'));
    return StreamHttpResponse(statusCode: statusCode, headers: headers, body: reader.take(n));
  }
  return StreamHttpResponse(statusCode: statusCode, headers: headers, body: reader.remaining());
}

Future<({int statusCode, Map<String, String> headers, List<int> body})> readBufferedResponse(
    Stream<List<int>> input) async {
  final resp = await readHttpResponse(input);
  final body = <int>[];
  await for (final c in resp.body) {
    body.addAll(c);
  }
  return (statusCode: resp.statusCode, headers: resp.headers, body: body);
}

Stream<List<int>> _dechunk(_ByteReader reader) async* {
  while (true) {
    final sizeLine = await reader.readLine();
    final size = int.parse(sizeLine.split(';').first.trim(), radix: 16);
    if (size == 0) {
      await reader.readLine(); // final CRLF (no trailers from dockerd)
      return;
    }
    yield* reader.take(size);
    await reader.readLine(); // CRLF after the chunk data
  }
}

/// On-demand byte reader with an internal buffer over a single subscription.
class _ByteReader {
  final StreamIterator<List<int>> _it;
  final List<int> _buf = [];
  bool _done = false;
  _ByteReader(Stream<List<int>> source) : _it = StreamIterator(source);

  Future<bool> _fill() async {
    if (_done) return false;
    if (await _it.moveNext()) {
      _buf.addAll(_it.current);
      return true;
    }
    _done = true;
    return false;
  }

  Future<List<int>?> readUntil(List<int> pattern) async {
    var search = 0;
    while (true) {
      final idx = _indexOf(_buf, pattern, search);
      if (idx != -1) {
        final end = idx + pattern.length;
        final out = _buf.sublist(0, end);
        _buf.removeRange(0, end);
        return out;
      }
      search = (_buf.length - pattern.length + 1).clamp(0, _buf.length);
      if (!await _fill()) return null;
    }
  }

  Future<String> readLine() async {
    final bytes = await readUntil(const [13, 10]);
    if (bytes == null) throw const StreamHttpException('unexpected end of stream (line)');
    return ascii.decode(bytes.sublist(0, bytes.length - 2));
  }

  Stream<List<int>> take(int n) async* {
    var remaining = n;
    while (remaining > 0) {
      if (_buf.isEmpty && !await _fill()) {
        throw const StreamHttpException('unexpected end of body');
      }
      final t = remaining < _buf.length ? remaining : _buf.length;
      yield _buf.sublist(0, t);
      _buf.removeRange(0, t);
      remaining -= t;
    }
  }

  Stream<List<int>> remaining() async* {
    if (_buf.isNotEmpty) {
      yield List<int>.from(_buf);
      _buf.clear();
    }
    while (await _fill()) {
      if (_buf.isNotEmpty) {
        yield List<int>.from(_buf);
        _buf.clear();
      }
    }
  }
}

int _indexOf(List<int> hay, List<int> needle, int start) {
  outer:
  for (var i = start < 0 ? 0 : start; i <= hay.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ssh/stream_http_test.dart && flutter analyze`
Expected: PASS (7 tests); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/transport/ssh/stream_http.dart app/test/transport/ssh/stream_http_test.dart
git commit -m "feat(app): minimal HTTP/1.1-over-stream client (CL/chunked/upgrade)"
```

---

## Task 4: SSH connector seam

**Files:**
- Modify: `app/pubspec.yaml` (add `dartssh2`)
- Create: `app/lib/src/transport/ssh/ssh_connection.dart`
- Modify: `docs/MANUAL-SMOKE-TEST.md`
- Test: `app/test/transport/ssh/docker_get_test.dart`

**Interfaces:**
- Consumes: `SshCredentials`/`SshAuthMethod` (Task 1), `fingerprintSha256` (Task 2), `writeHttpRequest`/`readBufferedResponse` (Task 3).
- Produces:
  - `class Duplex { final Stream<List<int>> input; final void Function(List<int>) add; final Future<void> Function() close; Duplex({required ...}); }`
  - `typedef HostKeyVerifier = bool Function(String presentedFingerprint);`
  - `class SshDaemonConnection { static Future<Duplex> open(SshCredentials creds, {required HostKeyVerifier verifyHostKey}); }`
  - `Future<({int statusCode, Map<String,String> headers, List<int> body})> dockerGet(Duplex conn, String path)`
  - `Future<String> sshDaemonVersion(SshCredentials creds, {required HostKeyVerifier verifyHostKey})`

- [ ] **Step 1: Add the dependency**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter pub add dartssh2`
Expected: `pubspec.yaml` gains `dartssh2:`; `pub get` succeeds.

- [ ] **Step 2: Write the failing test (the testable composition)**

Create `app/test/transport/ssh/docker_get_test.dart`:
```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';

void main() {
  test('dockerGet writes the request to the duplex and parses the response', () async {
    final written = <int>[];
    final response = ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n{"v":"1"}');
    final conn = Duplex(
      input: Stream.value(response),
      add: written.addAll,
      close: () async {},
    );
    final r = await dockerGet(conn, '/version');
    expect(r.statusCode, 200);
    expect(utf8.decode(r.body), '{"v":"1"}');
    expect(ascii.decode(written), contains('GET /version HTTP/1.1'));
    expect(ascii.decode(written), contains('Host: docker'));
  });
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ssh/docker_get_test.dart`
Expected: FAIL — `Duplex`/`dockerGet` undefined.

- [ ] **Step 4: Write the implementation**

Create `app/lib/src/transport/ssh/ssh_connection.dart`:
```dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../storage/credential_store.dart';
import 'host_key.dart';
import 'stream_http.dart';

/// A raw bidirectional byte stream to the remote dockerd socket.
class Duplex {
  final Stream<List<int>> input;
  final void Function(List<int>) add;
  final Future<void> Function() close;
  Duplex({required this.input, required this.add, required this.close});
}

/// Called with the presented host-key fingerprint; returns true to trust it.
typedef HostKeyVerifier = bool Function(String presentedFingerprint);

/// Opens an SSH session running `docker system dial-stdio` and exposes its
/// stdio as a [Duplex]. The live dartssh2 calls are not unit-tested (manual
/// smoke); keep this thin.
class SshDaemonConnection {
  static Future<Duplex> open(SshCredentials creds, {required HostKeyVerifier verifyHostKey}) async {
    final socket = await SSHSocket.connect(creds.host, creds.port);
    final client = SSHClient(
      socket,
      username: creds.username,
      onPasswordRequest:
          creds.authMethod == SshAuthMethod.password ? () => creds.password ?? '' : null,
      identities: creds.authMethod == SshAuthMethod.key && creds.privateKeyPem != null
          ? SSHKeyPair.fromPem(creds.privateKeyPem!, creds.passphrase)
          : null,
      onVerifyHostKey: (host, key) => verifyHostKey(fingerprintSha256(key)),
    );
    final session = await client.execute('docker system dial-stdio');
    return Duplex(
      input: session.stdout,
      add: (bytes) => session.stdin.add(Uint8List.fromList(bytes)),
      close: () async {
        session.close();
        client.close();
      },
    );
  }
}

/// Issues a GET over an already-open daemon [conn] and buffers the response.
Future<({int statusCode, Map<String, String> headers, List<int> body})> dockerGet(
    Duplex conn, String path) async {
  writeHttpRequest(conn.add, method: 'GET', path: path);
  return readBufferedResponse(conn.input);
}

/// Proves reach: connect over SSH, dial-stdio, GET /version. Manual-smoke only.
Future<String> sshDaemonVersion(SshCredentials creds, {required HostKeyVerifier verifyHostKey}) async {
  final conn = await SshDaemonConnection.open(creds, verifyHostKey: verifyHostKey);
  try {
    final resp = await dockerGet(conn, '/version');
    return utf8.decode(resp.body);
  } finally {
    await conn.close();
  }
}
```
**dartssh2 adaptation note (read this):** confirm against the installed `dartssh2` API — `SSHSocket.connect`, the `SSHClient` named params (`onPasswordRequest`, `identities`, `onVerifyHostKey`), `SSHKeyPair.fromPem(pem, passphrase)` (it returns `List<SSHKeyPair>`), and `client.execute(...)` returning a session with `stdout` (Stream) / `stdin` (sink) / `close()`. If a member's name or the host-key callback signature differs, ADAPT minimally to preserve behavior (host-key verdict via `fingerprintSha256` of the presented key) and note it in concerns. If the installed version exposes NO host-key callback, wire what it does offer and report it as a concern (do not silently drop verification). Keep `dockerGet`/`Duplex` exactly as specified (they are the tested surface).

- [ ] **Step 5: Run the test + analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/transport/ssh/docker_get_test.dart && flutter analyze && flutter test`
Expected: the new test passes; analyzer clean; **all** app tests pass.

- [ ] **Step 6: Document the manual smoke test**

In `docs/MANUAL-SMOKE-TEST.md`, append:
```markdown
## SSH (dial-stdio) — Phase 1D-2a

Reach over SSH (the live path; not unit-tested). Requires the `docker` CLI and docker access for the SSH user on the remote.

1. Ensure `ssh user@host docker system dial-stdio` works from a terminal (proves dial-stdio + permissions).
2. From a scratch Dart entrypoint or D2b's form, call `sshDaemonVersion(creds, verifyHostKey: (fp) { print('host key: $fp'); return true; })` with key auth, then password auth.
3. Verify it prints the daemon `/version` JSON. Note the printed fingerprint on first use; a second connect with that fingerprint pinned should return `HostKeyVerdict.match` (wired in D2b).
```

- [ ] **Step 7: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/src/transport/ssh/ssh_connection.dart app/test/transport/ssh/docker_get_test.dart docs/MANUAL-SMOKE-TEST.md
git commit -m "feat(app): SSH dial-stdio connector seam + dockerGet composition"
```

---

## Self-Review

**1. Spec coverage:**
- `dartssh2` + `crypto` deps → Tasks 4 / 2. ✓
- `SshCredentials` + `saveSsh`/`loadSsh`/`clearSsh` (single ssh slot, independent of tls) → Task 1. ✓
- Host-key TOFU (`fingerprintSha256` + `verifyHostKey` + `HostKeyVerdict`) → Task 2. ✓
- HTTP-over-stream (`writeHttpRequest` + `readHttpResponse` Content-Length/chunked/101/until-close + `readBufferedResponse` + `StreamHttpException`) → Task 3. ✓
- SSH connector seam (`Duplex`, `HostKeyVerifier`, `SshDaemonConnection.open` dartssh2, `dockerGet`, `sshDaemonVersion`) → Task 4. ✓
- Prove reach (`sshDaemonVersion` / `dockerGet`) → Task 4. ✓
- Manual smoke (live dial-stdio) → Task 4 Step 6. ✓
- Out of scope (SshTransport, streaming wiring, exec hijack, SshConnectionConfig, form, multi-host) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete. The dartssh2 seam carries an explicit adaptation note (the live API may differ by version) but ships concrete code.

**3. Type consistency:** `SshCredentials({host, port, username, authMethod, password?, privateKeyPem?, passphrase?, pinnedHostKey?})` + `SshAuthMethod` (Task 1) are consumed identically in Task 4. `fingerprintSha256(List<int>)` (Task 2) is called in Task 4's `onVerifyHostKey`. `writeHttpRequest(add, method:, path:, headers?, body?)` + `readBufferedResponse(input)` (Task 3) are called in Task 4's `dockerGet`. `Duplex({input, add, close})` + `dockerGet(Duplex, String)` (Task 4) match the Task 4 test. `HostKeyVerifier = bool Function(String)` is the param type of `open`/`sshDaemonVersion`. ✓
