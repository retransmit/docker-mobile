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
