# docker-mobile Phase 1D-3 — Saved Connection Profiles — Design Spec

**Date:** 2026-06-26
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 0/1A/1B/1C-*/1D-1/1D-2a/1D-2b (all on `main`). Final slice of sub-project **D**; completes Milestone 1 (multi-host quality-of-life).

---

## 1. Summary

D3 lets users save **multiple named connection profiles** across all three transports, land on a **profiles list** at launch, and **tap a profile to connect immediately**. The connect logic (including SSH's async host-key TOFU) is extracted out of the three forms into one shared `ConnectionLauncher` reused by both the list and the editor forms.

## 2. Goals / Non-goals

**Goals**
- `AgentCredentials` (new) + `ConnectionProfile` (name + kind + agent/tls/ssh creds) reusing `TlsCredentials`/`SshCredentials`.
- `ProfileStore` (secure storage; a JSON list under one key) — `list/add/update/delete`; in-memory fake; `profileStoreProvider`.
- `ConnectionLauncher.launch(context, ref, profile)` — the shared connect orchestration (agent/TLS synchronous build; SSH handshake + TOFU + re-pin-persist), then set `transportProvider` + navigate.
- `ProfilesScreen` as the launch landing — list, tap-to-connect, Edit/Delete, **+** to add.
- The three forms become **profile editors** (required Name; **Save** and **Save & Connect**; edit-mode prefill), with their inline connect logic moved to the launcher.

**Non-goals (this slice)**
- Profile folders/grouping, drag-reorder, search, import/export, QR pairing.
- Anonymous one-off connect (the model is profile-centric — create a named profile, then connect).
- Connection pooling, multi-connection-at-once, or a disconnect/teardown flow (a known pre-existing gap; out of scope).
- Changing transport behavior or the Go agent.

## 3. Scope decisions (locked)

- **Tap a profile → connect immediately** (agent/TLS build synchronously; SSH runs handshake + TOFU showing the mismatch dialog when needed). This is why the connect orchestration is extracted.
- **Profiles list is the home screen** (replaces `ConnectionScreen` as `home`).
- **Profiles store full credentials** (token/certs/key/password/pinned host key) in secure storage — convenience is the point; the store is the Keychain/Keystore.
- **Profile-centric** — no anonymous quick-connect; the editor always saves a named profile (Save or Save & Connect).
- **Single-slot prefill superseded:** `CredentialStore.{saveTls,loadTls,...,saveSsh,...}` are no longer used for prefill (profiles replace them); leave the methods in place (still used by their unit tests) but the forms no longer call them.
- **SSH TOFU re-pin persists into the profile:** firstUse and Trust-new-key write the resolved fingerprint back to the stored `ConnectionProfile`.
- **Error-path hygiene** (close SSH client on failure, mounted guards) carried from D2b.

## 4. Architecture

```
main: home = ProfilesScreen
  ProfilesScreen (list of ConnectionProfile)
    tap row -> ConnectionLauncher.launch(context, ref, profile)
    row menu -> Edit (open editor prefilled) | Delete (ProfileStore.delete)
    FAB + -> ConnectionScreen (editor, create mode)

ConnectionScreen (editor)  [was the connect landing]
  Name field + SegmentedButton(Agent|TCP+TLS|SSH) -> AgentForm | TlsForm | SshForm
  each form: Save (persist profile -> pop) | Save & Connect (persist -> launch)

ConnectionLauncher.launch(context, ref, profile)        [lib/src/connect/connection_launcher.dart]
  agent -> AgentConnectionConfig(creds).build() -> transportProvider -> HomeScreen
  tls   -> try TlsConnectionConfig(creds).build() (TlsConfigException -> snackbar) -> ... 
  ssh   -> sshConnectionFactory(creds); connect(verifier w/ TOFU);
           firstUse/Trust -> persist pin into profile (ProfileStore.update);
           mismatch -> warning dialog (Cancel/Trust); set transport -> HomeScreen

ProfileStore (abstract)                                  [lib/src/storage/profile_store.dart]
  list()/add()/update()/delete()  -- SecureProfileStore (key 'profiles' = JSON list) | InMemoryProfileStore
```

## 5. Components

### 5.1 Models — `lib/src/storage/profile_store.dart` (+ credential reuse)
- `class AgentCredentials { final String baseUri; final String token; toJson/fromJson; }` — defined in `credential_store.dart` alongside `TlsCredentials`/`SshCredentials`.
- `enum ConnectionKind { agent, tls, ssh }`.
- `class ConnectionProfile { final String id; final String name; final ConnectionKind kind; final AgentCredentials? agent; final TlsCredentials? tls; final SshCredentials? ssh; toJson/fromJson; ConnectionProfile copyWith({...}); }` — `id` is a caller-supplied unique string (e.g. a monotonic/uuid-ish string built in the editor; no `Math.random`/`DateTime.now` in pure code — generate in the widget layer).
- `String get host` convenience (agent host / tls host / ssh host) for the list subtitle.

### 5.2 ProfileStore — `lib/src/storage/profile_store.dart`
- `abstract class ProfileStore { Future<List<ConnectionProfile>> list(); Future<void> add(ConnectionProfile); Future<void> update(ConnectionProfile); Future<void> delete(String id); }`.
- `SecureProfileStore` — `flutter_secure_storage` key `profiles`, value = `jsonEncode(list.map(toJson))`; `add` appends, `update` replaces by id, `delete` filters by id.
- `InMemoryProfileStore` — a `List<ConnectionProfile>` for tests.
- `profileStoreProvider = Provider<ProfileStore>((ref) => SecureProfileStore());` (overridable).

### 5.3 ConnectionLauncher — `lib/src/connect/connection_launcher.dart`
- `Future<void> launchConnection(BuildContext context, WidgetRef ref, ConnectionProfile profile)`:
  - **agent:** `AgentConnectionConfig(baseUri: Uri.parse(creds.baseUri), token: creds.token).build()` → set transport → `HomeScreen`.
  - **tls:** `try { TlsConnectionConfig(...).build() } on TlsConfigException` → snackbar (no nav); else set transport → `HomeScreen`.
  - **ssh:** create via `sshConnectionFactoryProvider`; a verifier capturing the presented fingerprint + `verifyHostKey(profile.ssh.pinnedHostKey, fp)`; `connect`; `firstUse`/`match` → if pin changed, `ProfileStore.update` the profile with the new pin → set transport → `HomeScreen`; `mismatch` → warning dialog (Cancel / Trust new key → retry pinning the presented fp + persist); auth/unreachable → snackbar; close the SSH client on failure.
  - Capture messenger/navigator before awaits; mounted guards; the only place the SSH TOFU dialog lives now.

### 5.4 UI
- `ProfilesScreen` (`ConsumerWidget`, home): watches a `profilesProvider` (`FutureProvider` → `profileStoreProvider.list()`); `ListView` of `ListTile`s (leading icon by kind, title name, subtitle `kind · host`); `onTap` → `launchConnection`; trailing `PopupMenuButton` Edit/Delete (Delete → `delete` + invalidate); `FloatingActionButton` → `ConnectionScreen(editing: null)`. Empty state: "No saved connections — tap + to add one."
- `ConnectionScreen` (editor) — gains an optional `ConnectionProfile? editing`; a **Name** `TextField`; the existing `SegmentedButton`; passes the name + editing profile down to the active form. (When `editing != null`, lock/prefill the kind.)
- `AgentForm`/`TlsForm`/`SshForm` — gain `{String name, ConnectionProfile? editing}` (or read shared editor state); remove inline connect/persist; add **Save** (build a `ConnectionProfile` with an id [new uuid-ish for create, existing id for edit] → `add`/`update` → pop to list) and **Save & Connect** (persist → `launchConnection`). Prefill from `editing` when present.
- App entry (`app.dart`/`main.dart`) — `home: const ProfilesScreen()`.

## 6. Data flow & error handling
- Launch: as in 5.3; TLS/agent errors → snackbar, no nav; SSH mismatch → dialog; SSH firstUse/trust → persist the pin into the profile before navigating.
- Edit/Delete/Add operate on `ProfileStore` and invalidate `profilesProvider` so the list refreshes.
- Save validates per kind (host/port/required creds) before persisting; an invalid form → snackbar, no save.
- No secrets logged; everything stays in secure storage + memory.

## 7. File structure
```
app/lib/src/storage/credential_store.dart            # + AgentCredentials
app/lib/src/storage/profile_store.dart               # ConnectionProfile + ProfileStore (+ secure/in-memory)
app/lib/src/connect/connection_launcher.dart         # launchConnection (shared orchestration)
app/lib/src/state/providers.dart                     # + profileStoreProvider + profilesProvider
app/lib/src/ui/profiles_screen.dart                  # ProfilesScreen (home)
app/lib/src/ui/connection_screen.dart                # editor: Name + editing profile
app/lib/src/ui/connect/agent_form.dart               # profile editor (Save / Save & Connect)
app/lib/src/ui/connect/tls_form.dart                 # profile editor
app/lib/src/ui/connect/ssh_form.dart                 # profile editor (connect via launcher)
app/lib/main.dart (or app.dart)                       # home = ProfilesScreen
app/test/...                                           # mirrors the above
```

## 8. Testing
- Models: `ConnectionProfile`/`AgentCredentials` round-trip for all three kinds (with the unused-kind fields null); `host` getter.
- `ProfileStore` (in-memory): `add`→`list`; `update` replaces by id; `delete` removes by id; survives JSON encode/decode (Secure path covered structurally by the same JSON used by InMemory).
- `ConnectionLauncher` (widget; fake `SshConnection` via `sshConnectionFactoryProvider`, in-memory `ProfileStore`, fake transports): agent → an `AgentTransport`; TLS valid → a `TlsTransport`; TLS bad PEM → snackbar + no transport; SSH firstUse → an `SshTransport` + the profile is updated with the pinned fingerprint; SSH mismatch → warning dialog → **Trust new key** re-pins the stored profile + connects.
- `ProfilesScreen`: renders saved profiles (name + host); tapping a row calls the launcher (assert via a navigated `HomeScreen` or a set `transportProvider`); Delete removes a profile from the store; **+** opens the editor.
- Forms: Name required (blank → snackbar, no save); **Save** persists a profile of the right kind with the entered params; **Save & Connect** persists then launches; edit-mode prefills.

## 9. Dependencies
None new (`flutter_secure_storage` from D1). Profile ids: a small id generator in the widget layer (e.g. a counter seeded from `list().length` + name, or a time-based string built in the UI) — kept out of pure/testable code.

## 10. Open questions / to confirm during planning
- Profile `id` generation: simplest is a UI-layer `DateTime.now().microsecondsSinceEpoch.toString()` (allowed in widget code, not in pure logic) or `name`-derived; confirm uniqueness handling (reject duplicate names, or allow and disambiguate by id).
- Whether to migrate the existing `tls_last`/`ssh_last` single-slot values into a profile on first run; default: **no migration** (greenfield app, no real users) — just stop using the single slots.
- Whether `ConnectionScreen` keeps the 3-way `SegmentedButton` in edit mode or locks the kind; default: **lock the kind when editing** (a profile's transport type is fixed; delete + re-add to change).
