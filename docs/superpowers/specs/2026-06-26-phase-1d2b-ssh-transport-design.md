# docker-mobile Phase 1D-2b — SSH Transport + UI — Design Spec

**Date:** 2026-06-26
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 0/1A/1B/1C-*/1D-1/1D-2a (all on `main`). Second half of sub-project **D2 — SSH transport**; finishes SSH end-to-end.

---

## 1. Summary

D2b composes the D2a primitives into a working **`SshTransport`** (the full `Transport` contract over per-request `docker system dial-stdio` channels), wires it into the app with an SSH connect form, and implements the **host-key TOFU** UX. After D2b the app drives Docker over SSH end-to-end — list/logs/exec/system — with one shared SSH connection per session.

## 2. Goals / Non-goals

**Goals**
- Extract D1's `SocketExecChannel` into a shared `duplex_exec_channel.dart` (reused by both TLS and SSH; no SSH→TLS coupling).
- `SshTransport implements Transport` over an injected `Future<Duplex> Function()` opener — `get/post/delete` (buffered), `stream/postStream` (streamed, channel closed on cancel/done), `execAttach` (hijack: `POST /exec/{id}/start` Upgrade → `101` raw remainder → `ExecChannel`).
- `SshConnection` abstraction + `RealSshConnection` (the `dartssh2` seam): one shared client established once (`connect(verifier)` runs the handshake + host-key TOFU), a cheap dial-stdio channel per request (`openChannel() → Duplex`), `close()`.
- `sshConnectionFactoryProvider` (overridable with a fake in tests).
- `SshForm` + a 3rd `SegmentedButton` segment (Agent · TCP+TLS · SSH): host/port/username, key-or-password auth, connect-with-progress, host-key TOFU (pin on first use, **warn + trust-or-cancel on change**), prefill/persist via the `ssh_last` slot.

**Non-goals (this slice)**
- Saved multi-host profiles / a known-hosts map beyond the single pinned `ssh_last` (D3).
- SSH agent-forwarding, jump hosts, keyboard-interactive auth (YAGNI).
- Connection pooling beyond one shared client (channels are already cheap).
- Changing the agent/TLS transports' behavior or the Go agent.

## 3. Scope decisions (locked)

- **Shared client, channel-per-request:** the expensive SSH handshake happens **once** (in `SshConnection.connect`); each `Transport` call opens a fresh dial-stdio channel (`openChannel`). Mirrors Docker's `ssh://` helper.
- **No `SshConnectionConfig`:** SSH connect is async (handshake + TOFU), which doesn't fit the synchronous sealed `ConnectionConfig.build()`. The form orchestrates `connect()` then builds `SshTransport(openDuplex: conn.openChannel)` directly. The sealed `ConnectionConfig` stays Agent/Tls only.
- **`SocketExecChannel` is reused** (extracted to a shared file), not reimplemented.
- **TOFU UX:** `firstUse` → accept + pin the fingerprint into the saved creds; `match` → accept; `mismatch` → a blocking warning dialog offering **Cancel** or **Trust new key** (re-pin). Auth failure / unreachable → error, no navigation.
- **Pin value:** the fingerprint compared/pinned is the `dartssh2` host-key fingerprint with the `SHA256:` prefix stripped (byte-identical to `fingerprintSha256()`; established in D2a).
- **Per-request channel lifecycle:** buffered methods open→write→read→close; streaming methods keep the channel open until done/cancel then close it.

## 4. Architecture

```
ConnectionScreen SegmentedButton: Agent | TCP+TLS | SSH(new)
  SshForm: host/port/username + (key PEM+passphrase | password) + [Connect]
    conn = sshConnectionFactory(creds)              // RealSshConnection (or fake in tests)
    await conn.connect(verifyHostKey: tofuVerifier)  // handshake + TOFU; throws on mismatch/auth-fail
      firstUse -> pin captured fingerprint into creds; match -> ok; mismatch -> warn dialog
    transportProvider = SshTransport(openDuplex: conn.openChannel)
    save creds (with pin); navigate HomeScreen

SshTransport implements Transport            (lib/src/transport/ssh/ssh_transport.dart)
  get/post/delete -> openDuplex(); writeHttpRequest; readBufferedResponse; close -> http.Response
  stream/postStream -> openDuplex(); write; readHttpResponse; pipe body; close on cancel/done
  execAttach -> openDuplex(); POST /exec/{id}/start (Upgrade); readHttpResponse(101);
                SocketExecChannel(input: body, onSend: conn.add, onClose: conn.close)

SshConnection (abstract)                     (lib/src/transport/ssh/ssh_connection.dart)
  RealSshConnection: dartssh2 shared SSHClient; connect(verifier); openChannel()->Duplex; close()

SocketExecChannel  (moved)                   (lib/src/transport/duplex_exec_channel.dart)
  reused by TlsTransport (D1) and SshTransport
```

## 5. Components

### 5.1 Shared exec channel — `lib/src/transport/duplex_exec_channel.dart`
- Move `SocketExecChannel` here unchanged (`{input, onSend, onClose}` → `ExecChannel`). `tls_transport.dart` imports it and re-`export`s it so existing imports/tests keep working.

### 5.2 SshTransport — `lib/src/transport/ssh/ssh_transport.dart`
- `class SshTransport implements Transport { SshTransport({required Future<Duplex> Function() openDuplex}); }`.
- Helper `_pathWithQuery(path, query)` → `Uri(path: path, queryParameters: query).toString()`.
- `get/delete`: open → `writeHttpRequest(GET|DELETE)` → `readBufferedResponse` → `http.Response.bytes(body, status, headers: headers)` → close (finally).
- `post`: same with a JSON-encoded non-String body + `Content-Type: application/json` (no auth header).
- `stream/postStream`: a `StreamController` that on listen opens the channel, writes the request, `readHttpResponse`, gates 200, pipes `body`; closes the channel on done; `onCancel` cancels + closes the channel.
- `execAttach`: open → `writeHttpRequest(POST, /exec/$id/start, headers {Connection: Upgrade, Upgrade: tcp}, body {Detach:false,Tty:true})` → `readHttpResponse` → `SocketExecChannel(input: resp.body, onSend: conn.add, onClose: conn.close)`.

### 5.3 SshConnection — `lib/src/transport/ssh/ssh_connection.dart` (extend D2a file)
- `abstract class SshConnection { Future<void> connect({required HostKeyVerifier verifyHostKey}); Future<Duplex> openChannel(); Future<void> close(); }`.
- `class RealSshConnection implements SshConnection` — holds `SshCredentials` + a lazily-set `SSHClient`. `connect`: `SSHSocket.connect` → `SSHClient(username, onPasswordRequest|identities, onVerifyHostKey: (type, fp) => verifyHostKey(<strip 'SHA256:' from fp>))` → `await client.authenticated` (forces handshake + auth + the host-key callback). `openChannel`: `client.execute('docker system dial-stdio')` → `Duplex`. `close`: `client.close()`.
- D2a's one-shot `SshDaemonConnection.open`/`sshDaemonVersion` remain for the manual smoke.

### 5.4 State — `lib/src/state/providers.dart`
- `sshConnectionFactoryProvider = Provider<SshConnection Function(SshCredentials)>((ref) => (c) => RealSshConnection(c));` — tests override with a fake factory.

### 5.5 UI
- `ConnectionScreen` — add an **SSH** `ButtonSegment` (`Icons.terminal`); 3 segments → `AgentForm` / `TlsForm` / `SshForm`.
- `SshForm` (`ConsumerStatefulWidget`): host, port (`22`), username, an auth-method toggle (SegmentedButton/Radio: **Key** | **Password**) revealing either a private-key PEM field (+ passphrase) or a password field. **Connect**:
  1. validate (host, port 1–65535, username; key-or-password present).
  2. `conn = ref.read(sshConnectionFactoryProvider)(creds)`.
  3. `await conn.connect(verifyHostKey: tofuVerifier)` with a progress indicator. `tofuVerifier(fp)` captures `fp`, computes `verifyHostKey(creds.pinnedHostKey, fp)` → returns `verdict != mismatch`.
  4. on success: persist creds with `pinnedHostKey = capturedFp`; `transportProvider = SshTransport(openDuplex: conn.openChannel)`; navigate.
  5. on `connect` throwing after a `mismatch` verdict → a **"host key changed"** dialog (Cancel / Trust new key); *Trust* re-pins (`pinnedHostKey = capturedFp`) and retries the connect; *Cancel* aborts.
  6. other errors (auth/unreachable) → error snackbar, no navigation. Capture messenger/navigator before awaits; dispose all controllers.
- Prefill from `loadSsh()` on init (mounted-guarded).

## 6. Data flow & error handling
- Connect is an explicit, awaited step in the form (progress shown), so auth / host-key / reachability errors surface **at connect time**, not later inside a provider.
- Each `Transport` call opens its own dial-stdio channel over the shared client and closes it; a per-request failure surfaces through `DockerApiClient`/the screen's error state as today.
- Streaming closes the channel on cancel; exec keeps the channel for the session and closes on `ExecChannel.close`.
- Host-key `mismatch` fails closed (verifier returns false → `connect` throws) and is the only path to the warning dialog; there is no silent accept-any.
- No secrets logged; key/password/passphrase live only in secure storage + memory.

## 7. File structure
```
app/lib/src/transport/duplex_exec_channel.dart       # moved SocketExecChannel (shared)
app/lib/src/transport/tls_transport.dart             # import + re-export SocketExecChannel
app/lib/src/transport/ssh/ssh_transport.dart         # SshTransport
app/lib/src/transport/ssh/ssh_connection.dart        # + SshConnection abstract + RealSshConnection
app/lib/src/state/providers.dart                     # + sshConnectionFactoryProvider
app/lib/src/ui/connection_screen.dart                # 3rd SSH segment
app/lib/src/ui/connect/ssh_form.dart                 # SshForm
app/test/...                                           # mirrors (except the live RealSshConnection seam)
```

## 8. Testing
- `duplex_exec_channel`: the extraction keeps D1's `SocketExecChannel`/exec tests green (re-export verified).
- `SshTransport` (in-memory `Duplex` fakes returning canned response bytes):
  - `get`/`delete` build the right request line + parse status/headers/body into `http.Response`; `post` sends a JSON body + `Content-Type`, no `Authorization`.
  - `stream` yields the body bytes; canceling the subscription closes the channel (assert via a close-flag on the fake `Duplex`).
  - `execAttach` writes `POST /exec/{id}/start` with the Upgrade headers; the returned `ExecChannel.output` yields the raw remainder and `send` writes back to the channel.
- `SshForm`/`ConnectionScreen` (fake `SshConnection` via `sshConnectionFactoryProvider`):
  - the SSH segment reveals the fields; the auth toggle swaps key↔password.
  - validation blocks connect (snackbar, transport stays null).
  - **firstUse**: no stored pin → fake `connect` invokes the verifier with a fingerprint, succeeds → `transportProvider` is an `SshTransport` and the saved creds carry `pinnedHostKey`.
  - **mismatch**: a stored pin ≠ the presented fingerprint → fake `connect` throws → the warning dialog appears; **Trust new key** re-pins + connects.
  - prefill from a seeded `ssh_last`.
- `MANUAL-SMOKE-TEST.md`: extend the SSH section — connect via the form (key + password), drive list/logs/**exec**/system over SSH; verify first-use pinning then a reconnect matches, and that a changed host key shows the warning.

## 9. Dependencies
None new (`dartssh2` + `crypto` added in D2a).

## 10. Open questions / to confirm during planning
- `dartssh2` API: confirm `await client.authenticated` (or the equivalent) forces the handshake + host-key callback + auth so `connect` can resolve/throw deterministically; confirm `SSHSession.stdin`/`stdout`/`close` shapes (matched in D2a).
- Whether `RealSshConnection.openChannel` must guard against use before `connect` (throw a clear error); default: yes, throw `StateError('not connected')`.
- `http.Response.bytes` charset: Docker sends `application/json` without a charset, so `.body` defaults to latin1 — identical to the existing Agent/TLS transports (consistent, not a regression); no special-casing this slice.
