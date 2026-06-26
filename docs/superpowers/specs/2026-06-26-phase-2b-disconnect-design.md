# docker-mobile Phase 2B — Disconnect / Switch-Host Flow — Design Spec

**Date:** 2026-06-26
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** All of Milestone 1 + Phase 2A (on `main`). Closes the long-standing gap flagged across the D reviews: no transport ever closes its client.

---

## 1. Summary

Phase 2B adds a **Disconnect** action that tears down the active transport (closing the SSH/TLS/agent client) and returns to the profiles list, so users can cleanly switch hosts without leaking connections. It introduces `Transport.close()` and a small `disconnect(...)` orchestration; the UI lives as a confirm-dialog-guarded action on the System dashboard.

## 2. Goals / Non-goals

**Goals**
- `Future<void> close()` on the `Transport` interface; implemented by all three transports (close the HTTP client / shared SSH client).
- `SshTransport` gains an optional `onClose`; `ConnectionLauncher` wires it to `SshConnection.close` so the shared SSH client is actually closed.
- `disconnect(BuildContext, WidgetRef)` — pop to `ProfilesScreen`, null `transportProvider`, close the transport.
- A **Disconnect** app-bar action on `SystemScreen`, guarded by a confirm dialog.

**Non-goals (this slice)**
- Reconnect/keep-alive/health monitoring; multiple simultaneous connections.
- A per-tab disconnect (System tab only).
- Showing the connected host name in the dialog (the transport doesn't track its origin profile; a generic message is used).
- A shared test `FakeTransport` base refactor (tempting given the churn, but out of scope — each fake gets a one-line stub).

## 3. Scope decisions (locked)

- **`Transport.close()` on the interface** (polymorphic teardown). Every existing test fake implementing `Transport` gains `Future<void> close() async {}`.
- **Pop-first ordering:** `disconnect` pops back to the first route BEFORE nulling `transportProvider` + closing, so `HomeScreen`'s providers dispose without an error flash.
- **SSH close path:** `SshTransport({..., Future<void> Function()? onClose})`; `close()` awaits `onClose?.call()`. `ConnectionLauncher._launchSsh` passes `conn.close`. (Agent/TLS close their `http.Client`/`IOClient`.)
- **Placement:** a single `IconButton(Icons.logout)` on `SystemScreen`'s app bar → confirm dialog → `disconnect`.
- **Idempotency:** `close()` is safe to call when already closed (the SSH `onClose`/`RealSshConnection.close` are null-safe; closing an `http.Client` twice is harmless).

## 4. Architecture

```
SystemScreen app bar: [refresh] [logout]
  logout -> confirm dialog 'Disconnect from this daemon?' -> disconnect(context, ref)

disconnect(context, ref)                       [lib/src/connect/disconnect.dart]
  navigator.popUntil((r) => r.isFirst)         // -> ProfilesScreen (disposes HomeScreen + providers)
  transportProvider = null
  await transport?.close()

Transport (interface)  + Future<void> close()
  AgentTransport.close() -> _client.close()
  TlsTransport.close()   -> _client.close()         // closes the HttpClient
  SshTransport.close()   -> await _onClose?.call()  // = SshConnection.close (shared client)

ConnectionLauncher._launchSsh: SshTransport(openDuplex: conn.openChannel, onClose: conn.close)
```

## 5. Components

### 5.1 Transport interface — `lib/src/transport/transport.dart`
- Add `Future<void> close();` to `abstract class Transport`.

### 5.2 Transport impls
- `AgentTransport`: `@override Future<void> close() async => _client.close();` (the per-stream clients from `_streamClientFactory` are already closed on stream cancel/done).
- `TlsTransport`: `@override Future<void> close() async => _client.close();`.
- `SshTransport`: add `final Future<void> Function()? _onClose;` (constructor param `onClose`); `@override Future<void> close() async => await _onClose?.call();`. `ConnectionLauncher._launchSsh` builds `SshTransport(openDuplex: conn.openChannel, onClose: conn.close)`.

### 5.3 Test fakes
- Every `class _Fake... implements Transport` in `app/test/**` gains `@override Future<void> close() async {}`. (Mechanical; ~10 files.)

### 5.4 Disconnect orchestration — `lib/src/connect/disconnect.dart`
- `Future<void> disconnect(BuildContext context, WidgetRef ref) async`:
  - `final navigator = Navigator.of(context);`
  - `final transport = ref.read(transportProvider);`
  - `navigator.popUntil((r) => r.isFirst);`
  - `ref.read(transportProvider.notifier).state = null;`
  - `await transport?.close();`

### 5.5 UI — `SystemScreen`
- Add an app-bar `IconButton(icon: Icon(Icons.logout), tooltip: 'Disconnect')` whose `onPressed` shows a confirm `AlertDialog` ("Disconnect from this daemon?", Cancel / Disconnect); on **Disconnect** → `await disconnect(context, ref)`. Capture navigator before the await (the dialog returns a bool first; `disconnect` itself captures its own navigator).

## 6. Data flow & error handling
- Disconnect: confirm → pop to ProfilesScreen → null transport → close client. Closing failures are swallowed (best-effort teardown; the user is already back at the list). `transport?.close()` is null-safe.
- After disconnect, the profiles list is shown; selecting a profile reconnects fresh (a new transport, a new SSH client).
- No new error states; the existing screens simply unmount on pop.

## 7. File structure
```
app/lib/src/transport/transport.dart            # + close() on the interface
app/lib/src/transport/agent_transport.dart      # + close()
app/lib/src/transport/tls_transport.dart        # + close()
app/lib/src/transport/ssh/ssh_transport.dart    # + onClose + close()
app/lib/src/connect/connection_launcher.dart    # pass onClose: conn.close
app/lib/src/connect/disconnect.dart             # disconnect(context, ref)
app/lib/src/ui/system_screen.dart               # + Disconnect app-bar action + confirm dialog
app/test/**                                       # + close() stub on every Transport fake; new disconnect/system tests
```

## 8. Testing
- `AgentTransport.close()` / `TlsTransport.close()`: construct with an injected fake `http.Client` (the existing constructors accept `client`); assert `close()` calls the fake's `close()`.
- `SshTransport.close()`: construct with an `onClose` recording closure; assert `close()` invokes it (and is null-safe when `onClose` is absent).
- `disconnect`: a widget harness sets `transportProvider` to a fake transport recording `close()`, pushes a dummy screen on top of a first route, calls `disconnect`, then asserts `transportProvider` is null, the fake's `close()` ran, and the navigator popped to the first route.
- `SystemScreen`: the Disconnect `IconButton` is present; tapping shows the confirm dialog; tapping **Disconnect** nulls `transportProvider` (assert via a container read) — using a fake transport + a router so the pop target exists.
- Full suite stays green after the interface change (every fake updated).

## 9. Dependencies
None new.

## 10. Open questions / to confirm during planning
- Whether `SystemScreen`'s Disconnect test needs a two-route harness (ProfilesScreen → System) to exercise `popUntil`; default: test `disconnect` directly with a two-route harness, and test `SystemScreen` only for the action + dialog presence + the provider-null effect.
- `IOClient.close()` semantics: confirm it closes the underlying `HttpClient` (it does); no separate `HttpClient.close()` needed.
- Confirm none of the existing fakes already declare `close()` (they don't — `close()` is new to the interface).
