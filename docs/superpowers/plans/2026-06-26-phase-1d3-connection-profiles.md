# Phase 1D-3 — Saved Connection Profiles — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Save multiple named connection profiles, land on a profiles list, and tap a profile to connect immediately across all three transports.

**Architecture:** A `ConnectionProfile` (name + kind + reused per-transport creds) persisted as a JSON list by `ProfileStore`. The connect logic (including SSH host-key TOFU) is extracted from the three forms into one `launchConnection` used by both the list (tap-to-connect) and the editor forms. `ProfilesScreen` is the new home; the forms become profile editors.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `flutter_secure_storage` (from D1).

## Global Constraints

- **Profile-centric:** the editor always saves a *named* profile (Save or Save & Connect); no anonymous quick-connect.
- **Tap a profile → connect immediately** via the shared `launchConnection` (agent/TLS build synchronously; SSH runs handshake + TOFU with the mismatch dialog).
- **Profiles list is `home`** (replaces `ConnectionScreen`). Profiles store full credentials in secure storage.
- **SSH TOFU re-pin persists into the profile** (firstUse + Trust-new-key write the resolved fingerprint back via `ProfileStore.update`).
- **Single-slot prefill is superseded:** the forms no longer call `CredentialStore.loadTls/saveTls/loadSsh/saveSsh` (those methods stay for their own unit tests). No migration of old single-slot values.
- **Editing locks the kind;** changing transport type = delete + re-add.
- **Error-path hygiene** (close SSH client on failure; capture messenger/navigator before awaits; mounted guards) carried from D2b.
- **Scope:** app-only; no Go agent / transport-behavior changes; no folders/reorder/search/import/export; no disconnect flow.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/storage/credential_store.dart            # + AgentCredentials
app/lib/src/storage/profile_store.dart               # ConnectionProfile + ProfileStore (+ secure/in-memory) + newProfileId
app/lib/src/connect/connection_launcher.dart         # launchConnection (shared orchestration)
app/lib/src/state/providers.dart                     # + profileStoreProvider + profilesProvider
app/lib/src/ui/profiles_screen.dart                  # ProfilesScreen (home)
app/lib/src/ui/connection_screen.dart                # editor: kind selector + editing profile
app/lib/src/ui/connect/agent_form.dart               # profile editor
app/lib/src/ui/connect/tls_form.dart                 # profile editor
app/lib/src/ui/connect/ssh_form.dart                 # profile editor (connect via launcher)
app/lib/main.dart                                     # home = ProfilesScreen
app/test/...                                           # mirrors the above
```

---

## Task 1: Profile model + store

**Files:**
- Modify: `app/lib/src/storage/credential_store.dart` (add `AgentCredentials`)
- Create: `app/lib/src/storage/profile_store.dart`
- Modify: `app/lib/src/state/providers.dart`
- Test: `app/test/storage/profile_store_test.dart`

**Interfaces:**
- Produces:
  - `class AgentCredentials { final String baseUri, token; toJson/fromJson; }`
  - `enum ConnectionKind { agent, tls, ssh }`
  - `class ConnectionProfile { final String id, name; final ConnectionKind kind; final AgentCredentials? agent; final TlsCredentials? tls; final SshCredentials? ssh; String get host; ConnectionProfile copyWith({...}); toJson/fromJson; }`
  - `abstract class ProfileStore { Future<List<ConnectionProfile>> list(); Future<void> add(ConnectionProfile); Future<void> update(ConnectionProfile); Future<void> delete(String id); }` + `InMemoryProfileStore`, `SecureProfileStore`.
  - `String newProfileId()`
  - `profileStoreProvider`, `profilesProvider`.

- [ ] **Step 1: Write the failing test**

Create `app/test/storage/profile_store_test.dart`:
```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';

ConnectionProfile _agent(String id, String name) => ConnectionProfile(
    id: id, name: name, kind: ConnectionKind.agent,
    agent: const AgentCredentials(baseUri: 'http://h:8080', token: 't'));

void main() {
  test('agent/tls/ssh profiles round-trip via JSON', () {
    final agent = _agent('1', 'A');
    expect(ConnectionProfile.fromJson(agent.toJson()).agent!.baseUri, 'http://h:8080');

    final tls = ConnectionProfile(id: '2', name: 'T', kind: ConnectionKind.tls,
        tls: const TlsCredentials(host: 'th', port: 2376, clientCertPem: 'c', clientKeyPem: 'k'));
    final tls2 = ConnectionProfile.fromJson(tls.toJson());
    expect(tls2.kind, ConnectionKind.tls);
    expect(tls2.tls!.host, 'th');
    expect(tls2.agent, isNull);

    final ssh = ConnectionProfile(id: '3', name: 'S', kind: ConnectionKind.ssh,
        ssh: const SshCredentials(host: 'sh', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p', pinnedHostKey: 'FP'));
    final ssh2 = ConnectionProfile.fromJson(ssh.toJson());
    expect(ssh2.ssh!.pinnedHostKey, 'FP');
    expect(ssh2.host, 'sh');
  });

  test('host getter resolves per kind', () {
    expect(_agent('1', 'A').host, 'h');
  });

  test('store add/list/update/delete', () async {
    final store = InMemoryProfileStore();
    await store.add(_agent('1', 'A'));
    await store.add(_agent('2', 'B'));
    expect((await store.list()).length, 2);

    await store.update(_agent('1', 'A2'));
    expect((await store.list()).firstWhere((p) => p.id == '1').name, 'A2');

    await store.delete('2');
    final ids = (await store.list()).map((p) => p.id).toList();
    expect(ids, ['1']);
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/storage/profile_store_test.dart`
Expected: FAIL — types undefined.

- [ ] **Step 3: Add AgentCredentials**

In `app/lib/src/storage/credential_store.dart`, add near `TlsCredentials`:
```dart
class AgentCredentials {
  final String baseUri;
  final String token;
  const AgentCredentials({required this.baseUri, required this.token});
  Map<String, dynamic> toJson() => {'baseUri': baseUri, 'token': token};
  factory AgentCredentials.fromJson(Map<String, dynamic> json) =>
      AgentCredentials(baseUri: json['baseUri'] as String, token: json['token'] as String? ?? '');
}
```

- [ ] **Step 4: Create the profile store**

Create `app/lib/src/storage/profile_store.dart`:
```dart
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_store.dart';

enum ConnectionKind { agent, tls, ssh }

/// A unique id for a new profile (UI-layer; never compared for value in tests).
String newProfileId() => DateTime.now().microsecondsSinceEpoch.toString();

class ConnectionProfile {
  final String id;
  final String name;
  final ConnectionKind kind;
  final AgentCredentials? agent;
  final TlsCredentials? tls;
  final SshCredentials? ssh;

  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.kind,
    this.agent,
    this.tls,
    this.ssh,
  });

  String get host => switch (kind) {
        ConnectionKind.agent => Uri.tryParse(agent?.baseUri ?? '')?.host ?? '',
        ConnectionKind.tls => tls?.host ?? '',
        ConnectionKind.ssh => ssh?.host ?? '',
      };

  ConnectionProfile copyWith({String? name, AgentCredentials? agent, TlsCredentials? tls, SshCredentials? ssh}) =>
      ConnectionProfile(
        id: id,
        name: name ?? this.name,
        kind: kind,
        agent: agent ?? this.agent,
        tls: tls ?? this.tls,
        ssh: ssh ?? this.ssh,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'agent': agent?.toJson(),
        'tls': tls?.toJson(),
        'ssh': ssh?.toJson(),
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) => ConnectionProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: ConnectionKind.values.byName(json['kind'] as String),
        agent: json['agent'] == null ? null : AgentCredentials.fromJson(json['agent'] as Map<String, dynamic>),
        tls: json['tls'] == null ? null : TlsCredentials.fromJson(json['tls'] as Map<String, dynamic>),
        ssh: json['ssh'] == null ? null : SshCredentials.fromJson(json['ssh'] as Map<String, dynamic>),
      );
}

abstract class ProfileStore {
  Future<List<ConnectionProfile>> list();
  Future<void> add(ConnectionProfile profile);
  Future<void> update(ConnectionProfile profile);
  Future<void> delete(String id);
}

class InMemoryProfileStore implements ProfileStore {
  final List<ConnectionProfile> _profiles = [];
  @override
  Future<List<ConnectionProfile>> list() async => List.unmodifiable(_profiles);
  @override
  Future<void> add(ConnectionProfile profile) async => _profiles.add(profile);
  @override
  Future<void> update(ConnectionProfile profile) async {
    final i = _profiles.indexWhere((p) => p.id == profile.id);
    if (i >= 0) _profiles[i] = profile;
  }
  @override
  Future<void> delete(String id) async => _profiles.removeWhere((p) => p.id == id);
}

class SecureProfileStore implements ProfileStore {
  static const _key = 'profiles';
  final FlutterSecureStorage _storage;
  SecureProfileStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  Future<List<ConnectionProfile>> _read() async {
    final v = await _storage.read(key: _key);
    if (v == null) return [];
    return (jsonDecode(v) as List).map((e) => ConnectionProfile.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _write(List<ConnectionProfile> ps) =>
      _storage.write(key: _key, value: jsonEncode(ps.map((p) => p.toJson()).toList()));

  @override
  Future<List<ConnectionProfile>> list() => _read();
  @override
  Future<void> add(ConnectionProfile profile) async {
    final ps = await _read();
    ps.add(profile);
    await _write(ps);
  }
  @override
  Future<void> update(ConnectionProfile profile) async {
    final ps = await _read();
    final i = ps.indexWhere((p) => p.id == profile.id);
    if (i >= 0) ps[i] = profile;
    await _write(ps);
  }
  @override
  Future<void> delete(String id) async {
    final ps = await _read();
    ps.removeWhere((p) => p.id == id);
    await _write(ps);
  }
}
```

In `app/lib/src/state/providers.dart`, add `import '../storage/profile_store.dart';` and:
```dart
final profileStoreProvider = Provider<ProfileStore>((ref) => SecureProfileStore());
final profilesProvider = FutureProvider<List<ConnectionProfile>>((ref) => ref.watch(profileStoreProvider).list());
```

- [ ] **Step 5: Run the test + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/storage/profile_store_test.dart && flutter analyze`
Expected: PASS (3 tests); analyzer clean.

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/storage/credential_store.dart app/lib/src/storage/profile_store.dart app/lib/src/state/providers.dart app/test/storage/profile_store_test.dart
git commit -m "feat(app): ConnectionProfile + ProfileStore (multi-host persistence)"
```

---

## Task 2: ConnectionLauncher (shared connect orchestration)

**Files:**
- Create: `app/lib/src/connect/connection_launcher.dart`
- Test: `app/test/connect/connection_launcher_test.dart`

**Interfaces:**
- Consumes: `ConnectionProfile`/`ConnectionKind` (profile_store.dart), `AgentConnectionConfig`/`TlsConnectionConfig` (connection_config.dart), `TlsConfigException` (tls_security.dart), `sshConnectionFactoryProvider`/`profileStoreProvider`/`profilesProvider`/`transportProvider` (providers.dart), `verifyHostKey`/`HostKeyVerdict` (host_key.dart), `SshTransport` (ssh_transport.dart), `HomeScreen`.
- Produces: `Future<void> launchConnection(BuildContext context, WidgetRef ref, ConnectionProfile profile)`.

- [ ] **Step 1: Write the failing test**

Create `app/test/connect/connection_launcher_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/connect/connection_launcher.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_transport.dart';

class _FakeSshConnection implements SshConnection {
  final String fingerprint;
  _FakeSshConnection(this.fingerprint);
  @override
  Future<void> connect({required HostKeyVerifier verifyHostKey}) async {
    if (!verifyHostKey(fingerprint)) throw Exception('host key rejected');
  }
  @override
  Future<Duplex> openChannel() async => Duplex(input: const Stream.empty(), add: (_) {}, close: () async {});
  @override
  Future<void> close() async {}
}

Future<ProviderContainer> _launch(WidgetTester tester, ConnectionProfile p,
    {ProfileStore? store, SshConnection Function(SshCredentials)? sshFactory}) async {
  final s = store ?? InMemoryProfileStore();
  late ProviderContainer container;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      profileStoreProvider.overrideWithValue(s),
      if (sshFactory != null) sshConnectionFactoryProvider.overrideWithValue(sshFactory),
    ],
    child: MaterialApp(
      home: Consumer(builder: (context, ref, _) {
        container = ProviderScope.containerOf(context);
        return ElevatedButton(onPressed: () => launchConnection(context, ref, p), child: const Text('go'));
      }),
    ),
  ));
  await tester.tap(find.text('go'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

void main() {
  testWidgets('agent profile sets an AgentTransport', (tester) async {
    final c = await _launch(tester,
        const ConnectionProfile(id: '1', name: 'A', kind: ConnectionKind.agent,
            agent: AgentCredentials(baseUri: 'http://127.0.0.1:8080', token: 't')));
    expect(c.read(transportProvider), isA<AgentTransport>());
  });

  testWidgets('SSH firstUse pins the fingerprint into the stored profile', (tester) async {
    final store = InMemoryProfileStore();
    const profile = ConnectionProfile(id: '9', name: 'S', kind: ConnectionKind.ssh,
        ssh: SshCredentials(host: '127.0.0.1', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p'));
    await store.add(profile);
    final c = await _launch(tester, profile, store: store, sshFactory: (_) => _FakeSshConnection('FP-NEW'));
    expect(c.read(transportProvider), isA<SshTransport>());
    expect((await store.list()).single.ssh!.pinnedHostKey, 'FP-NEW');
  });

  testWidgets('SSH mismatch shows the dialog; Trust re-pins the stored profile', (tester) async {
    final store = InMemoryProfileStore();
    const profile = ConnectionProfile(id: '9', name: 'S', kind: ConnectionKind.ssh,
        ssh: SshCredentials(host: '127.0.0.1', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p', pinnedHostKey: 'FP-OLD'));
    await store.add(profile);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        profileStoreProvider.overrideWithValue(store),
        sshConnectionFactoryProvider.overrideWithValue((_) => _FakeSshConnection('FP-NEW')),
      ],
      child: MaterialApp(
        home: Consumer(builder: (context, ref, _) =>
            ElevatedButton(onPressed: () => launchConnection(context, ref, profile), child: const Text('go'))),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    expect(find.textContaining('host key'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, 'Trust new key'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect((await store.list()).single.ssh!.pinnedHostKey, 'FP-NEW');
  });
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/connect/connection_launcher_test.dart`
Expected: FAIL — `launchConnection` undefined.

- [ ] **Step 3: Write the launcher**

Create `app/lib/src/connect/connection_launcher.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../storage/credential_store.dart';
import '../storage/profile_store.dart';
import '../transport/connection_config.dart';
import '../transport/ssh/host_key.dart';
import '../transport/ssh/ssh_transport.dart';
import '../transport/tls_security.dart';
import '../transport/transport.dart';
import '../ui/home_screen.dart';

/// Establishes a transport from a saved [profile] and navigates to the home
/// screen. The only place the SSH host-key TOFU dialog lives.
Future<void> launchConnection(BuildContext context, WidgetRef ref, ConnectionProfile profile) async {
  switch (profile.kind) {
    case ConnectionKind.agent:
      final a = profile.agent!;
      ref.read(transportProvider.notifier).state =
          AgentConnectionConfig(baseUri: Uri.parse(a.baseUri), token: a.token).build();
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HomeScreen()));
    case ConnectionKind.tls:
      final messenger = ScaffoldMessenger.of(context);
      final navigator = Navigator.of(context);
      final t = profile.tls!;
      final Transport transport;
      try {
        transport = TlsConnectionConfig(
          host: t.host, port: t.port,
          clientCertPem: t.clientCertPem, clientKeyPem: t.clientKeyPem,
          caPem: t.caPem, insecure: t.insecure,
        ).build();
      } on TlsConfigException catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Invalid certificate: ${e.message}')));
        return;
      }
      ref.read(transportProvider.notifier).state = transport;
      navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
    case ConnectionKind.ssh:
      await _launchSsh(context, ref, profile);
  }
}

Future<void> _launchSsh(BuildContext context, WidgetRef ref, ConnectionProfile profile, {String? overridePin}) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final ssh = profile.ssh!;
  final pin = overridePin ?? ssh.pinnedHostKey;
  final creds = SshCredentials(
    host: ssh.host, port: ssh.port, username: ssh.username, authMethod: ssh.authMethod,
    password: ssh.password, privateKeyPem: ssh.privateKeyPem, passphrase: ssh.passphrase, pinnedHostKey: pin,
  );
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

  try {
    await conn.connect(verifyHostKey: verifier);
  } catch (e) {
    await conn.close();
    if (mismatch && presented != null) {
      if (!context.mounted) return;
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
      if (trust == true && context.mounted) {
        await _launchSsh(context, ref, profile, overridePin: presented);
      }
      return;
    }
    messenger.showSnackBar(SnackBar(content: Text('Connection failed: $e')));
    return;
  }

  final newPin = pin ?? presented;
  if (newPin != ssh.pinnedHostKey) {
    await ref.read(profileStoreProvider).update(profile.copyWith(
          ssh: SshCredentials(
            host: ssh.host, port: ssh.port, username: ssh.username, authMethod: ssh.authMethod,
            password: ssh.password, privateKeyPem: ssh.privateKeyPem, passphrase: ssh.passphrase, pinnedHostKey: newPin,
          ),
        ));
    ref.invalidate(profilesProvider);
  }
  ref.read(transportProvider.notifier).state = SshTransport(openDuplex: conn.openChannel);
  navigator.push(MaterialPageRoute(builder: (_) => const HomeScreen()));
}
```

- [ ] **Step 4: Run the test + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/connect/connection_launcher_test.dart && flutter analyze`
Expected: PASS (3 tests); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/connect/connection_launcher.dart app/test/connect/connection_launcher_test.dart
git commit -m "feat(app): shared connection launcher (agent/tls/ssh-TOFU)"
```

---

## Task 3: Forms become profile editors

**Files:**
- Overwrite: `app/lib/src/ui/connect/agent_form.dart`, `tls_form.dart`, `ssh_form.dart`
- Overwrite: `app/lib/src/ui/connection_screen.dart`
- Test: replace `app/test/ui/connection_screen_test.dart`, `app/test/ui/ssh_form_test.dart`

**Interfaces:**
- Consumes: `launchConnection` (Task 2), `ConnectionProfile`/`ConnectionKind`/`newProfileId` (profile_store.dart), `profileStoreProvider`/`profilesProvider` (providers.dart), credential models.
- Produces: `AgentForm({ConnectionProfile? editing})`, `TlsForm({ConnectionProfile? editing})`, `SshForm({ConnectionProfile? editing})`, `ConnectionScreen({ConnectionProfile? editing})`.

- [ ] **Step 1: Write the failing tests (replace the old form tests)**

Replace `app/test/ui/connection_screen_test.dart` with:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';

Widget _wrap(ProfileStore store) => ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: ConnectionScreen()),
    );

void main() {
  testWidgets('Agent is default; selecting TCP+TLS reveals the cert fields', (tester) async {
    await tester.pumpWidget(_wrap(InMemoryProfileStore()));
    expect(find.widgetWithText(TextField, 'Token'), findsOneWidget);
    await tester.tap(find.text('TCP+TLS'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Client certificate (PEM)'), findsOneWidget);
  });

  testWidgets('Save persists an agent profile with the entered fields', (tester) async {
    final store = InMemoryProfileStore();
    await tester.pumpWidget(_wrap(store));
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'home');
    await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '10.0.0.2');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pump();
    final saved = await store.list();
    expect(saved.single.name, 'home');
    expect(saved.single.kind, ConnectionKind.agent);
    expect(saved.single.agent!.baseUri, 'http://10.0.0.2:8080');
  });

  testWidgets('blank name blocks Save', (tester) async {
    final store = InMemoryProfileStore();
    await tester.pumpWidget(_wrap(store));
    await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '10.0.0.2');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pump();
    expect(find.textContaining('name'), findsOneWidget);
    expect(await store.list(), isEmpty);
  });
}
```

Replace `app/test/ui/ssh_form_test.dart` with:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/connect/ssh_form.dart';

Widget _wrap(ProfileStore store, {ConnectionProfile? editing}) => ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SshForm(editing: editing)))),
    );

void main() {
  testWidgets('Save persists an SSH profile (password auth)', (tester) async {
    final store = InMemoryProfileStore();
    await tester.pumpWidget(_wrap(store));
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'box');
    await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '10.0.0.3');
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'root');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pump();
    final saved = (await store.list()).single;
    expect(saved.kind, ConnectionKind.ssh);
    expect(saved.ssh!.username, 'root');
    expect(saved.ssh!.authMethod, SshAuthMethod.password);
  });

  testWidgets('auth toggle reveals the private-key field', (tester) async {
    await tester.pumpWidget(_wrap(InMemoryProfileStore()));
    await tester.tap(find.text('Key'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Private key (PEM)'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/connection_screen_test.dart test/ui/ssh_form_test.dart`
Expected: FAIL — the forms don't have Name/Save yet.

- [ ] **Step 3: Overwrite `agent_form.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connect/connection_launcher.dart';
import '../../state/providers.dart';
import '../../storage/credential_store.dart';
import '../../storage/profile_store.dart';

class AgentForm extends ConsumerStatefulWidget {
  final ConnectionProfile? editing;
  const AgentForm({super.key, this.editing});
  @override
  ConsumerState<AgentForm> createState() => _AgentFormState();
}

class _AgentFormState extends ConsumerState<AgentForm> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '8080');
  final _token = TextEditingController();
  bool _useTls = false;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e?.agent != null) {
      _name.text = e!.name;
      final uri = Uri.tryParse(e.agent!.baseUri);
      _host.text = uri?.host ?? '';
      _port.text = '${uri?.port ?? 8080}';
      _token.text = e.agent!.token;
      _useTls = uri?.scheme == 'https';
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _token.dispose();
    super.dispose();
  }

  ConnectionProfile? _build() {
    final name = _name.text.trim();
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (name.isEmpty || host.isEmpty || port == null || port < 1 || port > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Enter a name, host, and port (1-65535).')));
      return null;
    }
    final baseUri = Uri(scheme: _useTls ? 'https' : 'http', host: host, port: port);
    return ConnectionProfile(
      id: widget.editing?.id ?? newProfileId(),
      name: name,
      kind: ConnectionKind.agent,
      agent: AgentCredentials(baseUri: baseUri.toString(), token: _token.text),
    );
  }

  Future<void> _persist(ConnectionProfile p) async {
    final store = ref.read(profileStoreProvider);
    widget.editing == null ? await store.add(p) : await store.update(p);
    ref.invalidate(profilesProvider);
  }

  Future<void> _save() async {
    final p = _build();
    if (p == null) return;
    final navigator = Navigator.of(context);
    await _persist(p);
    navigator.pop();
  }

  Future<void> _saveAndConnect() async {
    final p = _build();
    if (p == null) return;
    await _persist(p);
    if (!mounted) return;
    await launchConnection(context, ref, p);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
        TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host / IP')),
        TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
        TextField(controller: _token, decoration: const InputDecoration(labelText: 'Token'), obscureText: true),
        SwitchListTile(title: const Text('Use TLS (https)'), value: _useTls, onChanged: (v) => setState(() => _useTls = v)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: _save, child: const Text('Save'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: _saveAndConnect, child: const Text('Save & Connect'))),
        ]),
      ],
    );
  }
}
```

- [ ] **Step 4: Overwrite `tls_form.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connect/connection_launcher.dart';
import '../../state/providers.dart';
import '../../storage/credential_store.dart';
import '../../storage/profile_store.dart';

class TlsForm extends ConsumerStatefulWidget {
  final ConnectionProfile? editing;
  const TlsForm({super.key, this.editing});
  @override
  ConsumerState<TlsForm> createState() => _TlsFormState();
}

class _TlsFormState extends ConsumerState<TlsForm> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '2376');
  final _cert = TextEditingController();
  final _key = TextEditingController();
  final _ca = TextEditingController();
  bool _insecure = false;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e?.tls != null) {
      _name.text = e!.name;
      final t = e.tls!;
      _host.text = t.host;
      _port.text = '${t.port}';
      _cert.text = t.clientCertPem;
      _key.text = t.clientKeyPem;
      _ca.text = t.caPem ?? '';
      _insecure = t.insecure;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _cert.dispose();
    _key.dispose();
    _ca.dispose();
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  ConnectionProfile? _build() {
    final name = _name.text.trim();
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    if (name.isEmpty || host.isEmpty || port == null || port < 1 || port > 65535) {
      _snack('Enter a name, host, and port (1-65535).');
      return null;
    }
    if (_cert.text.trim().isEmpty || _key.text.trim().isEmpty) {
      _snack('Client certificate and key are required.');
      return null;
    }
    final ca = _ca.text.trim();
    return ConnectionProfile(
      id: widget.editing?.id ?? newProfileId(),
      name: name,
      kind: ConnectionKind.tls,
      tls: TlsCredentials(
        host: host, port: port,
        clientCertPem: _cert.text, clientKeyPem: _key.text,
        caPem: ca.isEmpty ? null : ca, insecure: _insecure,
      ),
    );
  }

  Future<void> _persist(ConnectionProfile p) async {
    final store = ref.read(profileStoreProvider);
    widget.editing == null ? await store.add(p) : await store.update(p);
    ref.invalidate(profilesProvider);
  }

  Future<void> _save() async {
    final p = _build();
    if (p == null) return;
    final navigator = Navigator.of(context);
    await _persist(p);
    navigator.pop();
  }

  Future<void> _saveAndConnect() async {
    final p = _build();
    if (p == null) return;
    await _persist(p);
    if (!mounted) return;
    await launchConnection(context, ref, p);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
        TextField(controller: _host, decoration: const InputDecoration(labelText: 'Host / IP')),
        TextField(controller: _port, decoration: const InputDecoration(labelText: 'Port'), keyboardType: TextInputType.number),
        TextField(controller: _cert, decoration: const InputDecoration(labelText: 'Client certificate (PEM)'), maxLines: 4),
        TextField(controller: _key, decoration: const InputDecoration(labelText: 'Client key (PEM)'), maxLines: 4),
        TextField(controller: _ca, decoration: const InputDecoration(labelText: 'CA certificate (PEM, optional)'), maxLines: 4),
        SwitchListTile(title: const Text('Allow insecure (skip server verification)'), value: _insecure, onChanged: (v) => setState(() => _insecure = v)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: _save, child: const Text('Save'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: _saveAndConnect, child: const Text('Save & Connect'))),
        ]),
      ],
    );
  }
}
```

- [ ] **Step 5: Overwrite `ssh_form.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../connect/connection_launcher.dart';
import '../../state/providers.dart';
import '../../storage/credential_store.dart';
import '../../storage/profile_store.dart';

class SshForm extends ConsumerStatefulWidget {
  final ConnectionProfile? editing;
  const SshForm({super.key, this.editing});
  @override
  ConsumerState<SshForm> createState() => _SshFormState();
}

class _SshFormState extends ConsumerState<SshForm> {
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '22');
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _passphrase = TextEditingController();
  SshAuthMethod _authMethod = SshAuthMethod.password;
  String? _pinnedHostKey;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    if (e?.ssh != null) {
      _name.text = e!.name;
      final s = e.ssh!;
      _host.text = s.host;
      _port.text = '${s.port}';
      _username.text = s.username;
      _authMethod = s.authMethod;
      _password.text = s.password ?? '';
      _key.text = s.privateKeyPem ?? '';
      _passphrase.text = s.passphrase ?? '';
      _pinnedHostKey = s.pinnedHostKey;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _username.dispose();
    _password.dispose();
    _key.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  void _snack(String m) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(m)));

  ConnectionProfile? _build() {
    final name = _name.text.trim();
    final host = _host.text.trim();
    final port = int.tryParse(_port.text.trim());
    final user = _username.text.trim();
    if (name.isEmpty || host.isEmpty || port == null || port < 1 || port > 65535 || user.isEmpty) {
      _snack('Enter a name, host, port (1-65535), and username.');
      return null;
    }
    if (_authMethod == SshAuthMethod.key && _key.text.trim().isEmpty) {
      _snack('A private key is required for key auth.');
      return null;
    }
    if (_authMethod == SshAuthMethod.password && _password.text.isEmpty) {
      _snack('A password is required for password auth.');
      return null;
    }
    return ConnectionProfile(
      id: widget.editing?.id ?? newProfileId(),
      name: name,
      kind: ConnectionKind.ssh,
      ssh: SshCredentials(
        host: host, port: port, username: user, authMethod: _authMethod,
        password: _authMethod == SshAuthMethod.password ? _password.text : null,
        privateKeyPem: _authMethod == SshAuthMethod.key ? _key.text : null,
        passphrase: _authMethod == SshAuthMethod.key && _passphrase.text.isNotEmpty ? _passphrase.text : null,
        pinnedHostKey: _pinnedHostKey,
      ),
    );
  }

  Future<void> _persist(ConnectionProfile p) async {
    final store = ref.read(profileStoreProvider);
    widget.editing == null ? await store.add(p) : await store.update(p);
    ref.invalidate(profilesProvider);
  }

  Future<void> _save() async {
    final p = _build();
    if (p == null) return;
    final navigator = Navigator.of(context);
    await _persist(p);
    navigator.pop();
  }

  Future<void> _saveAndConnect() async {
    final p = _build();
    if (p == null) return;
    await _persist(p);
    if (!mounted) return;
    await launchConnection(context, ref, p);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
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
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: _save, child: const Text('Save'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: _saveAndConnect, child: const Text('Save & Connect'))),
        ]),
      ],
    );
  }
}
```

- [ ] **Step 6: Overwrite `connection_screen.dart`**

```dart
import 'package:flutter/material.dart';

import '../storage/profile_store.dart';
import 'connect/agent_form.dart';
import 'connect/ssh_form.dart';
import 'connect/tls_form.dart';

class ConnectionScreen extends StatefulWidget {
  final ConnectionProfile? editing;
  const ConnectionScreen({super.key, this.editing});
  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> {
  late ConnectionKind _kind = widget.editing?.kind ?? ConnectionKind.agent;

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing;
    return Scaffold(
      appBar: AppBar(title: Text(editing == null ? 'Add connection' : 'Edit ${editing.name}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            if (editing == null)
              SegmentedButton<ConnectionKind>(
                segments: const [
                  ButtonSegment(value: ConnectionKind.agent, label: Text('Agent'), icon: Icon(Icons.dns)),
                  ButtonSegment(value: ConnectionKind.tls, label: Text('TCP+TLS'), icon: Icon(Icons.lock)),
                  ButtonSegment(value: ConnectionKind.ssh, label: Text('SSH'), icon: Icon(Icons.terminal)),
                ],
                selected: {_kind},
                onSelectionChanged: (s) => setState(() => _kind = s.first),
              ),
            const SizedBox(height: 16),
            Expanded(
              child: SingleChildScrollView(
                child: switch (_kind) {
                  ConnectionKind.agent => AgentForm(editing: editing),
                  ConnectionKind.tls => TlsForm(editing: editing),
                  ConnectionKind.ssh => SshForm(editing: editing),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 7: Run the form tests + analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/connection_screen_test.dart test/ui/ssh_form_test.dart && flutter analyze && flutter test`
Expected: the rewritten tests pass; analyzer clean. NOTE: `app/test/widget_test.dart` ("app boots to the connection screen") will now fail because the home screen changes in Task 4 — it is updated there. If it fails on this task only because `ConnectionScreen` no longer auto-builds on boot, leave it for Task 4 (do not delete it); all OTHER tests must pass.

- [ ] **Step 8: Commit**

```bash
git add app/lib/src/ui/connect/agent_form.dart app/lib/src/ui/connect/tls_form.dart app/lib/src/ui/connect/ssh_form.dart app/lib/src/ui/connection_screen.dart app/test/ui/connection_screen_test.dart app/test/ui/ssh_form_test.dart
git commit -m "feat(app): connect forms become profile editors (Save / Save & Connect)"
```

---

## Task 4: ProfilesScreen + app entry

**Files:**
- Create: `app/lib/src/ui/profiles_screen.dart`
- Modify: `app/lib/main.dart` (home → `ProfilesScreen`)
- Test: `app/test/ui/profiles_screen_test.dart`
- Modify: `app/test/widget_test.dart` (boots to ProfilesScreen)

**Interfaces:**
- Consumes: `profilesProvider`/`profileStoreProvider` (providers.dart), `launchConnection` (Task 2), `ConnectionScreen` (Task 3), `ConnectionProfile`/`ConnectionKind` (profile_store.dart).
- Produces: `class ProfilesScreen extends ConsumerWidget`.

- [ ] **Step 1: Write the failing test**

Create `app/test/ui/profiles_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';
import 'package:docker_mobile/src/ui/profiles_screen.dart';

Widget _wrap(ProfileStore store) => ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: ProfilesScreen()),
    );

void main() {
  testWidgets('empty state, then renders saved profiles', (tester) async {
    final store = InMemoryProfileStore();
    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();
    expect(find.textContaining('No saved connections'), findsOneWidget);

    await store.add(const ConnectionProfile(id: '1', name: 'prod', kind: ConnectionKind.ssh,
        ssh: SshCredentials(host: 'srv', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p')));
    // a fresh pump container picks up the seeded store
    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();
    expect(find.text('prod'), findsOneWidget);
    expect(find.textContaining('srv'), findsOneWidget);
  });

  testWidgets('+ opens the editor', (tester) async {
    await tester.pumpWidget(_wrap(InMemoryProfileStore()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionScreen), findsOneWidget);
  });

  testWidgets('Delete removes a profile', (tester) async {
    final store = InMemoryProfileStore();
    await store.add(const ConnectionProfile(id: '1', name: 'gone', kind: ConnectionKind.agent,
        agent: AgentCredentials(baseUri: 'http://h:8080', token: 't')));
    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(await store.list(), isEmpty);
    expect(find.text('gone'), findsNothing);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/profiles_screen_test.dart`
Expected: FAIL — `ProfilesScreen` undefined.

- [ ] **Step 3: Write ProfilesScreen**

Create `app/lib/src/ui/profiles_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../connect/connection_launcher.dart';
import '../state/providers.dart';
import '../storage/profile_store.dart';
import 'connection_screen.dart';

class ProfilesScreen extends ConsumerWidget {
  const ProfilesScreen({super.key});

  IconData _icon(ConnectionKind k) => switch (k) {
        ConnectionKind.agent => Icons.dns,
        ConnectionKind.tls => Icons.lock,
        ConnectionKind.ssh => Icons.terminal,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profiles = ref.watch(profilesProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Connections')),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionScreen())),
        child: const Icon(Icons.add),
      ),
      body: profiles.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (list) => list.isEmpty
            ? const Center(child: Text('No saved connections — tap + to add one.'))
            : ListView(
                children: [
                  for (final p in list)
                    ListTile(
                      leading: Icon(_icon(p.kind)),
                      title: Text(p.name),
                      subtitle: Text('${p.kind.name} · ${p.host}'),
                      onTap: () => launchConnection(context, ref, p),
                      trailing: PopupMenuButton<String>(
                        onSelected: (v) async {
                          if (v == 'edit') {
                            await Navigator.of(context).push(
                                MaterialPageRoute(builder: (_) => ConnectionScreen(editing: p)));
                          } else if (v == 'delete') {
                            await ref.read(profileStoreProvider).delete(p.id);
                            ref.invalidate(profilesProvider);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                    ),
                ],
              ),
      ),
    );
  }
}
```

- [ ] **Step 4: Point the app at ProfilesScreen**

In `app/lib/main.dart`, change the import of the home widget from `connection_screen.dart` to `profiles_screen.dart` and set `home: const ProfilesScreen()` (replace the existing `home: const ConnectionScreen()`). Leave the rest of `MaterialApp`/`ProviderScope` unchanged.

- [ ] **Step 5: Update the boot test**

In `app/test/widget_test.dart`, update the assertion so the app boots to `ProfilesScreen` (replace the `find.text('Connect to agent')` / `ConnectionScreen` expectation with `expect(find.byType(ProfilesScreen), findsOneWidget);` and add `import 'package:docker_mobile/src/ui/profiles_screen.dart';`). If it pumps the real app, the empty profiles list shows "No saved connections" — assert that text instead if `ProfilesScreen` type isn't imported in that test's scope.

- [ ] **Step 6: Run the new test + analyzer + full suite**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/profiles_screen_test.dart && flutter analyze && flutter test`
Expected: the new test passes; analyzer clean; **all** app tests pass (incl. the updated `widget_test.dart`).

- [ ] **Step 7: Commit**

```bash
git add app/lib/src/ui/profiles_screen.dart app/lib/main.dart app/test/ui/profiles_screen_test.dart app/test/widget_test.dart
git commit -m "feat(app): ProfilesScreen home + connect-from-profile"
```

---

## Self-Review

**1. Spec coverage:**
- `AgentCredentials` + `ConnectionProfile` + `ProfileStore` (+ provider/profilesProvider) → Task 1. ✓
- `launchConnection` (agent/tls/ssh-TOFU + re-pin-persist) → Task 2. ✓
- Forms → profile editors (Name, Save / Save & Connect, edit prefill, kind-lock via ConnectionScreen) → Task 3. ✓
- `ProfilesScreen` home (list/tap-connect/edit/delete/+) + app entry → Task 4. ✓
- Tap-to-connect; profiles-as-home; profile-centric; single-slot superseded; SSH re-pin persists; error-path hygiene → Tasks 2/3/4. ✓
- Out of scope (folders/reorder/search/import-export, anonymous connect, migration, disconnect) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Full file bodies given for new + overwritten files; `main.dart`/`widget_test.dart` carry exact change instructions (their current contents are small and app-specific).

**3. Type consistency:** `ConnectionProfile({id, name, kind, agent?, tls?, ssh?})` + `ConnectionKind` + `newProfileId()` + `copyWith` (Task 1) are constructed identically in Tasks 2/3. `ProfileStore.{list,add,update,delete}` (Task 1) called in Tasks 2/3/4. `launchConnection(context, ref, profile)` (Task 2) called by the forms' `_saveAndConnect` (Task 3) and `ProfilesScreen.onTap` (Task 4). `AgentConnectionConfig`/`TlsConnectionConfig`/`TlsConfigException`/`SshTransport`/`sshConnectionFactoryProvider`/`verifyHostKey`/`HostKeyVerdict` are existing symbols used as in their D1/D2 definitions. Form constructors `{ConnectionProfile? editing}` (Task 3) used by `ConnectionScreen` (Task 3). ✓
