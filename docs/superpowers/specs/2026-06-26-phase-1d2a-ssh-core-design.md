# docker-mobile Phase 1D-2a — SSH Transport Core — Design Spec

**Date:** 2026-06-26
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 0/1A/1B/1C-*/1D-1 (all on `main`). First half of sub-project **D2 — SSH transport** (D2a core; D2b adds the `Transport`, exec, and UI).

---

## 1. Summary

D2a builds the **plumbing to reach a Docker daemon over SSH** and proves end-to-end reach. It opens an SSH exec session running `docker system dial-stdio` (Docker's own `ssh://` mechanism) to get a raw duplex byte-stream to the remote `/var/run/docker.sock`, and over that stream runs a hand-rolled, **byte-testable minimal HTTP/1.1 client**. It adds SSH credential storage and a trust-on-first-use (TOFU) host-key policy. The full `SshTransport`, streaming wiring, exec hijack, and SSH form are **D2b**.

## 2. Goals / Non-goals

**Goals**
- `dartssh2` dependency.
- `SshCredentials` + `CredentialStore` SSH methods (`saveSsh`/`loadSsh`/`clearSsh`), single `ssh_last` slot.
- Host-key TOFU policy: a pure `verifyHostKey(stored?, presented) → HostKeyVerdict {firstUse, match, mismatch}` (SHA-256 fingerprint).
- **HTTP-over-stream client**: request serializer + response parser (status line, headers, Content-Length / chunked / connection-close framing), buffered mode (→ `http.Response`-like) and streamed mode (→ `Stream<List<int>>`), with `101 Upgrade` detection returning the raw remainder.
- SSH connector seam: `SshDaemonConnection.open(creds, verifier) → Duplex` wrapping `dartssh2` connect + `dial-stdio` (live part behind a thin seam).
- Prove reach: a read-only `GET /version` / `/_ping` over the stream returns a parsed response.

**Non-goals (this slice → D2b)**
- `SshTransport implements Transport` (full surface), `Stream`/`postStream` wiring into the app, exec hijack over SSH, `SshConnectionConfig`, the SSH connect form.
- Multi-host known-hosts map (D2a pins one host in `ssh_last`); multi-profile is D3.
- Connection pooling / HTTP keep-alive (one dial-stdio channel per request).

## 3. Scope decisions (locked)

- **Reach mechanism:** SSH exec `docker system dial-stdio` (NOT port-forward — `dartssh2` `direct-tcpip` can't reach a unix socket). Requires `docker` CLI + docker access on the remote (standard `ssh://` assumption; documented in the smoke test).
- **One dial-stdio channel per HTTP request** (new daemon "socket" per call). Pooling deferred (YAGNI).
- **Auth:** private key (PEM, optional passphrase) **or** username+password.
- **Host key:** TOFU — first connect captures + pins the SHA-256 fingerprint; later connects must match or the verdict is `mismatch` (D2b surfaces the refuse+warn UX). No accept-any in this slice.
- **HTTP client is hand-rolled** (dart:io `HttpClient` can't bind to an SSH channel — no constructible `ConnectionTask`, no Socket to attach). The parser is pure and byte-tested.
- **Testing seam:** the live `dartssh2` connect/dial-stdio sits behind `SshDaemonConnection` (manual-smoke covered); the HTTP parser, credential store, and TOFU decision are fully unit-tested.

## 4. Architecture

```
SshDaemonConnection.open(SshCredentials, HostKeyVerifier) -> Duplex   [seam; dartssh2]
  dartssh2: SSHSocket.connect(host, port)
           SSHClient(username, onPasswordRequest|identities, onVerifyHostKey -> verifier)
           session = client.execute('docker system dial-stdio')
           Duplex{ input: session.stdout, add: session.stdin.add, close: session.close }

StreamHttp (pure)                                  [lib/src/transport/ssh/stream_http.dart]
  writeRequest(add, method, path, headers?, body?)        -> bytes on the duplex
  readResponse(input)  -> StreamHttpResponse {status, headers, body bytes | body stream}
    framing: Content-Length | Transfer-Encoding: chunked | read-until-close
    detects 101 Upgrade -> raw remainder (for D2b exec)

host_key.dart (pure)                               [lib/src/transport/ssh/host_key.dart]
  fingerprintSha256(List<int> keyBytes) -> String
  verifyHostKey(String? stored, String presented) -> HostKeyVerdict

SshCredentials + CredentialStore.saveSsh/loadSsh/clearSsh   [lib/src/storage/credential_store.dart]
```

## 5. Components

### 5.1 Credential storage — extend `lib/src/storage/credential_store.dart`
- `enum SshAuthMethod { password, key }`.
- `class SshCredentials { host; int port; username; SshAuthMethod authMethod; String? password; String? privateKeyPem; String? passphrase; String? pinnedHostKey; toJson/fromJson; }`.
- `CredentialStore` gains `Future<void> saveSsh(SshCredentials)`, `Future<SshCredentials?> loadSsh()`, `Future<void> clearSsh()`. `InMemoryCredentialStore` stores a second JSON slot; `SecureCredentialStore` uses key `ssh_last`.

### 5.2 Host-key TOFU — `lib/src/transport/ssh/host_key.dart`
- `String fingerprintSha256(List<int> hostKeyBytes)` — base64 SHA-256 (OpenSSH `SHA256:` style, without the prefix), used to pin/compare.
- `enum HostKeyVerdict { firstUse, match, mismatch }`.
- `HostKeyVerdict verifyHostKey(String? storedFingerprint, String presentedFingerprint)` — `null` stored → `firstUse`; equal → `match`; else → `mismatch`. Pure; no I/O.

### 5.3 HTTP-over-stream — `lib/src/transport/ssh/stream_http.dart`
- `class StreamHttpException implements Exception { final String message; }`.
- `void writeHttpRequest(void Function(List<int>) add, {required String method, required String path, Map<String,String>? headers, List<int>? body})` — emits `METHOD path HTTP/1.1\r\nHost: docker\r\n` + caller headers + (Content-Length + body when present) + terminator. Deterministic header order for testability.
- `class StreamHttpResponse { final int statusCode; final Map<String,String> headers; final Stream<List<int>> body; bool get isUpgrade; }`.
- `Future<StreamHttpResponse> readHttpResponse(Stream<List<int>> input)` — buffers bytes, parses the status line + headers (to `\r\n\r\n`), then exposes `body` framed by: `Content-Length` (exact N bytes), `Transfer-Encoding: chunked` (de-chunked, boundaries may split across reads), `101` upgrade (`isUpgrade=true`, body = raw remainder), else read-until-close. A truncated head → `StreamHttpException`.
- `Future<({int statusCode, Map<String,String> headers, List<int> body})> readBufferedResponse(Stream<List<int>> input)` — convenience that drains `body` to bytes (for `get/post/delete` in D2b).

### 5.4 SSH connector seam — `lib/src/transport/ssh/ssh_connection.dart`
- `class Duplex { final Stream<List<int>> input; final void Function(List<int>) add; final Future<void> Function() close; }`.
- `typedef HostKeyVerifier = bool Function(String presentedFingerprint)` — D2b wires this to the TOFU policy + store; D2a's smoke uses accept-and-print.
- `class SshDaemonConnection { static Future<Duplex> open(SshCredentials creds, {required HostKeyVerifier verifyHostKey}) async {...} }` — `dartssh2`: `SSHSocket.connect` → `SSHClient` (password via `onPasswordRequest`, key via `SSHKeyPair.fromPem` identities, `onVerifyHostKey` → `verifyHostKey(fingerprintSha256(key))`) → `client.execute('docker system dial-stdio')` → `Duplex` over the session's stdout/stdin/close. Thin; not unit-tested.
- `Future<String> sshDaemonVersion(SshCredentials, {required HostKeyVerifier})` — opens a `Duplex`, `writeHttpRequest(GET /version)`, `readBufferedResponse`, returns the body. Proves reach (used by the manual smoke).

## 6. Data flow & error handling
- Reach: `SshDaemonConnection.open` → `Duplex`; on auth/host-key/exec failure, the `dartssh2` error propagates (D2b renders it).
- HTTP parse: a malformed/truncated head → `StreamHttpException`; a non-2xx is still parsed (status carried) so callers (D2b's `DockerApiClient`) map it as today.
- Host key: `verifyHostKey` returns `false` on `mismatch` → `dartssh2` aborts the handshake; D2b shows the warning.
- No secrets logged; private key/password live only in secure storage + memory.

## 7. File structure
```
app/lib/src/storage/credential_store.dart            # + SshCredentials + saveSsh/loadSsh/clearSsh
app/lib/src/transport/ssh/host_key.dart              # fingerprint + verifyHostKey (pure)
app/lib/src/transport/ssh/stream_http.dart           # writeHttpRequest + readHttpResponse (pure)
app/lib/src/transport/ssh/ssh_connection.dart        # Duplex + SshDaemonConnection (dartssh2 seam)
app/pubspec.yaml                                      # + dartssh2
docs/MANUAL-SMOKE-TEST.md                             # + SSH (dial-stdio) section
app/test/...                                           # mirrors the above (except the live seam)
```

## 8. Testing
- `SshCredentials`: `saveSsh`→`loadSsh` round-trips all fields for both auth methods (password-only: null key/passphrase; key: null password) and a null `pinnedHostKey`; `clearSsh` empties; SSH and TLS slots are independent.
- `host_key`: `fingerprintSha256` is stable/deterministic for given bytes; `verifyHostKey(null, x)=firstUse`, `verifyHostKey(x, x)=match`, `verifyHostKey(x, y)=mismatch`.
- `stream_http` (the bulk, in-memory byte fixtures):
  - `writeHttpRequest` emits exact bytes for a GET (no body) and a POST (JSON body + correct `Content-Length`).
  - `readHttpResponse` parses a `200` Content-Length JSON body; a `chunked` body reassembled across chunk boundaries split mid-chunk across input events; a `101 Upgrade` (`isUpgrade`, raw remainder passes through); a truncated head → `StreamHttpException`.
  - `readBufferedResponse` returns status + headers + full body bytes.
- `MANUAL-SMOKE-TEST.md`: add an SSH section — `sshDaemonVersion` against a real host (key and password auth; observe the first-use fingerprint, then a reconnect matches).

## 9. Dependencies
- **Add:** `dartssh2` (pure-Dart SSH client; password + publickey auth; `execute` sessions; `onVerifyHostKey`).

## 10. Open questions / to confirm during planning
- `dartssh2` host-key callback shape: confirm `onVerifyHostKey(String host, String type, Uint8List key)` and derive the SHA-256 fingerprint from `key`; pin to the current published major version.
- Private-key loading: `SSHKeyPair.fromPem(pem, passphrase)` returns a list; confirm the API and the encrypted-key passphrase path.
- Chunked-trailer handling: ignore trailers after the terminating `0\r\n` chunk (Docker rarely sends them); confirm the minimal parser tolerates an empty trailer line.
