# docker-mobile Phase 1D-1 — TCP+TLS (mTLS) Transport — Design Spec

**Date:** 2026-06-26
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 0/1A/1B/1C-* (all on `main`). First slice of sub-project **D — agent-less transports**.

---

## 1. Summary

D1 lets the app connect **directly to a Docker daemon over TCP+TLS (mutual TLS)** — no agent. It adds a `TlsTransport` satisfying the existing `Transport` contract entirely client-side (TLS sockets, chunked streaming, and a client-side exec hijack that replaces the agent's WebSocket bridge), a TLS `SecurityContext` builder with a CA-pinning verify policy + an opt-in insecure mode, minimal secure storage for the cert material, and a transport-type-aware connect form.

## 2. Goals / Non-goals

**Goals**
- `TlsTransport implements Transport` — `get/stream/post/execAttach/delete/postStream` direct to dockerd (default `:2376`), no bearer token.
- `tls_security.dart` — build an `HttpClient`/`SecurityContext` from client cert + key (+ optional CA) PEM bytes; CA-pinned verification by default; opt-in insecure (`badCertificateCallback => true`); typed `TlsConfigException` on malformed material.
- Client-side **exec hijack** over the TLS socket (`POST /exec/{id}/start` Upgrade → `detachSocket()` → duplex `ExecChannel`).
- `CredentialStore` (interface + `flutter_secure_storage` impl + in-memory fake) persisting one "last TCP+TLS connection".
- Connect screen: transport-type selector (Agent | TCP+TLS) + `TlsForm`.

**Non-goals (this slice)**
- SSH transport (**D2**), saved multi-host profiles (**D3**).
- File-picker cert import (paste PEM only this slice).
- Changing the agent transport's behavior, or the Go agent.

## 3. Scope decisions (locked)

- **Server verification:** default secure — supply the daemon's CA cert and verify against it (`setTrustedCertificatesBytes`, pinned). Plus an explicit, **off-by-default** "Allow insecure / skip verification" toggle that sets `badCertificateCallback => true`. Mirrors `docker --tlscacert`/`--tlsverify` vs `--tls`.
- **No bearer token** on any `TlsTransport` request (mTLS *is* the auth).
- **Exec:** TTY exec, raw stream (no stdcopy framing), matching the existing `ExecSessionController`; size via the existing `resizeExec` POST.
- **Default port:** `2376`.
- **Credential input:** paste PEM into text fields (client cert, client key, CA). No `file_picker` dependency this slice.
- **Persistence:** one "last connection" slot (host/port/3×PEM/insecure) in secure storage; multi-profile is D3.
- **Async + dialog discipline:** carried from prior slices (capture messenger/navigator before await; mounted-guarded post-await `setState`; no controllers leaked).

## 4. Architecture

```
ConnectionScreen
  [ transport type: Agent | TCP+TLS ]   <- SegmentedButton
    AgentForm (existing fields)  -> AgentTransport            (unchanged)
    TlsForm   (host/port/3xPEM/insecure) -> TlsTransport

TlsTransport implements Transport            (lib/src/transport/tls_transport.dart)
  built from HttpClient (dart:io) + baseUri
  get/post/delete    -> IOClient(httpClient)             -> http.Response
  stream/postStream  -> streamed http.Request over IOClient (no auth header)
  execAttach         -> POST /exec/{id}/start Upgrade -> detachSocket() -> _SocketExecChannel

tls_security.dart                             (lib/src/transport/tls_security.dart)
  buildTlsHttpClient({clientCertPem, clientKeyPem, caPem?, insecure}) -> HttpClient
    SecurityContext.useCertificateChainBytes + usePrivateKeyBytes (+ setTrustedCertificatesBytes)
    insecure -> httpClient.badCertificateCallback = (_,__,___) => true
    malformed PEM -> throw TlsConfigException

CredentialStore (interface)                   (lib/src/storage/credential_store.dart)
  saveTls(TlsCredentials) / loadTls() / clearTls()
    SecureCredentialStore  -> flutter_secure_storage   (real)
    InMemoryCredentialStore -> Map                      (tests)
```

## 5. Components

### 5.1 Connection config — `lib/src/transport/connection_config.dart`
- `sealed class ConnectionConfig { Transport build(); }`.
- `AgentConnectionConfig(baseUri, token)` → `AgentTransport`.
- `TlsConnectionConfig(host, port, clientCertPem, clientKeyPem, caPem?, insecure)` → `TlsTransport` (builds the `HttpClient` via `tls_security`).
- Keeps transport construction out of widgets and gives D2/D3 their extension point.

### 5.2 TLS security — `lib/src/transport/tls_security.dart`
- `class TlsConfigException implements Exception { final String message; }`.
- `HttpClient buildTlsHttpClient({required List<int> clientCertPem, required List<int> clientKeyPem, List<int>? caPem, bool insecure = false, String? keyPassword})`:
  - `final ctx = SecurityContext(withTrustedRoots: false);`
  - `ctx.useCertificateChainBytes(clientCertPem); ctx.usePrivateKeyBytes(clientKeyPem, password: keyPassword);`
  - if `caPem != null`: `ctx.setTrustedCertificatesBytes(caPem);`
  - `final c = HttpClient(context: ctx);`
  - if `insecure`: `c.badCertificateCallback = (cert, host, port) => true;`
  - wrap `TlsException`/`ArgumentError` from the dart:io calls in `TlsConfigException`.
  - return `c`.

### 5.3 TlsTransport — `lib/src/transport/tls_transport.dart`
- `class TlsTransport implements Transport` with `final Uri baseUri; final HttpClient _httpClient;` (and a `http.Client` `IOClient` wrapping it).
- Constructor: `TlsTransport({required this.baseUri, required HttpClient httpClient})` (injectable for tests); a `TlsTransport.fromConfig(TlsConnectionConfig)` convenience that calls `buildTlsHttpClient`.
- `get/post/delete`: delegate to the `IOClient` with `baseUri.replace(path, query)`; `post` JSON-encodes a non-String body and sets `Content-Type: application/json`; **no** `Authorization` header.
- `stream/postStream`: mirror `AgentTransport._openStream` (StreamController + onListen/onCancel, 200-gate, cancelable) over the `IOClient`, minus the bearer header.
- `execAttach(execId, {cols, rows})`:
  - `final req = await _httpClient.openUrl('POST', baseUri.replace(path: '/exec/$execId/start'));`
  - headers: `Content-Type: application/json`, `Connection: Upgrade`, `Upgrade: tcp`; write body `{"Detach":false,"Tty":true}`.
  - `final resp = await req.close();` then `final socket = await resp.detachSocket();`
  - return `_SocketExecChannel(socket)`.
- `_SocketExecChannel implements ExecChannel`: `output` = the socket stream (cached, single-subscription); `send(bytes)` = `socket.add(bytes)`; `close()` = guard + `socket.destroy()`.

### 5.4 Credential storage — `lib/src/storage/credential_store.dart`
- `class TlsCredentials { host, port, clientCertPem, clientKeyPem, caPem?, insecure; toJson/fromJson; }`.
- `abstract class CredentialStore { Future<void> saveTls(TlsCredentials); Future<TlsCredentials?> loadTls(); Future<void> clearTls(); }`.
- `SecureCredentialStore` — `flutter_secure_storage` under a single key (`tls_last`), value = JSON.
- `InMemoryCredentialStore` — a `Map<String,String>` for tests.
- A `credentialStoreProvider` (overridable in tests).

### 5.5 UI
- `ConnectionScreen` — a `SegmentedButton`/`ToggleButtons` (Agent | TCP+TLS) above the form; shows `AgentForm` or `TlsForm`.
- `AgentForm` — the existing host/port/token/use-TLS fields, extracted from today's `ConnectionScreen` (behavior unchanged); builds `AgentConnectionConfig`.
- `TlsForm` — host, port (`2376`), client-cert PEM, client-key PEM, CA PEM (multiline), **Allow insecure** switch. Validates host (non-empty), port (1–65535), cert+key present; on connect: `config.build()` → set `transportProvider` → `credentialStore.saveTls(...)` → push `HomeScreen`. On init, pre-fill from `credentialStore.loadTls()`.

## 6. Data flow & error handling
- Connect: `TlsForm` validates → `TlsConnectionConfig.build()` (may throw `TlsConfigException` on bad PEM → shown as a snackbar, no navigation) → `transportProvider` set → creds saved → navigate.
- Requests: identical surface to `AgentTransport`; non-2xx handled by `DockerApiClient` as today. TLS handshake/cert failures surface as the stream/future error (a `HandshakeException`/`TlsException`) and render in each screen's existing error state.
- Exec: a hijack/handshake failure throws from `execAttach`; the `ExecScreen` shows its error path (unchanged).
- Insecure toggle off + untrusted server → handshake fails (expected); on → connects (documented as insecure).

## 7. File structure
```
app/lib/src/transport/connection_config.dart      # sealed ConnectionConfig + Agent/Tls variants
app/lib/src/transport/tls_security.dart           # buildTlsHttpClient + TlsConfigException
app/lib/src/transport/tls_transport.dart          # TlsTransport + _SocketExecChannel
app/lib/src/storage/credential_store.dart         # TlsCredentials + CredentialStore (+ secure/in-memory)
app/lib/src/state/providers.dart                  # + credentialStoreProvider
app/lib/src/ui/connection_screen.dart             # transport-type selector (refactor)
app/lib/src/ui/connect/agent_form.dart            # extracted agent form
app/lib/src/ui/connect/tls_form.dart              # TLS form
app/pubspec.yaml                                   # + flutter_secure_storage
app/test/...                                        # mirrors the above
```

## 8. Testing
- `tls_security`: valid client cert+key (+CA) → `HttpClient` built; malformed PEM → `TlsConfigException`; `insecure:true` sets a `badCertificateCallback` that returns true (and is null when false). (Use small self-signed PEM fixtures generated for the test.)
- `TlsTransport`: with an injected/faked `HttpClient` (or client factory), `get/post/delete/stream/postStream` build the right URI/method/body and send **no** `Authorization` header; `stream` is cancelable and 200-gated; the hijack path returns an `ExecChannel` whose `send`/`output`/`close` map to the (in-memory) socket.
- `CredentialStore`: `saveTls`→`loadTls` round-trips all fields (incl. null CA, insecure flag); `clearTls` empties it — via `InMemoryCredentialStore`.
- `ConnectionScreen`/`TlsForm`: selecting **TCP+TLS** reveals the PEM fields; invalid host/port or missing cert/key blocks connect with a snackbar; a valid submit sets a `TlsTransport` on `transportProvider` and persists credentials (assert against an injected `InMemoryCredentialStore`); pre-fill from a pre-seeded store.
- `MANUAL-SMOKE-TEST.md`: add a TCP+TLS section — run `dockerd` with `--tlsverify --tlscacert/--tlscert/--tlskey`, connect with the matching client cert/key/CA, exercise list/logs/**exec**/stats end-to-end (the real socket + hijack path that unit tests cannot cover).

## 9. Dependencies
- **Add:** `flutter_secure_storage` (Keychain/Keystore). mTLS uses dart:io built-ins; `dartssh2` is deferred to D2.

## 10. Open questions / to confirm during planning
- Exact Docker hijack handshake for `POST /exec/{id}/start`: confirm `Connection: Upgrade`/`Upgrade: tcp` + `detachSocket()` against the Engine API and whether any pre-buffered response bytes must be drained before the first read; the injectable socket seam isolates this for the manual smoke test.
- `flutter_secure_storage` major version: pin the current stable in the plan.
- Whether to expose an optional client-key passphrase field now or defer (default: support the `keyPassword` param in `tls_security` but omit the UI field this slice — YAGNI).
