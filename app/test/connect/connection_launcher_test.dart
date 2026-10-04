import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/connect/connection_launcher.dart';
import 'package:docker_mobile/src/session/transport_factory.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/home_screen.dart';

import '../support/fake_session.dart';

const agent = ConnectionProfile(id: '1', name: 'A', kind: ConnectionKind.agent,
    agent: AgentCredentials(baseUri: 'http://127.0.0.1:8080', token: 't'));
ConnectionProfile ssh({String? pin}) => ConnectionProfile(id: '9', name: 'S', kind: ConnectionKind.ssh,
    ssh: SshCredentials(host: '127.0.0.1', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p', pinnedHostKey: pin));

Future<ProviderContainer> pumpLauncher(WidgetTester tester, ConnectionProfile p, FakeTransportFactory factory,
    {ProfileStore? store}) async {
  late ProviderContainer container;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      profileStoreProvider.overrideWithValue(store ?? InMemoryProfileStore()),
      transportFactoryProvider.overrideWithValue(factory),
      lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
    ],
    child: MaterialApp(
      home: Consumer(builder: (context, ref, _) {
        container = ProviderScope.containerOf(context);
        return Scaffold(body: ElevatedButton(onPressed: () => launchConnection(context, ref, p), child: const Text('go')));
      }),
    ),
  ));
  await tester.tap(find.text('go'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return container;
}

void main() {
  testWidgets('a reachable daemon connects the session and opens Home', (tester) async {
    final d = FakeDaemon();
    final c = await pumpLauncher(tester, agent, FakeTransportFactory([d.transport]));
    await tester.pump(const Duration(milliseconds: 500));
    expect(c.read(transportProvider), same(d.transport));
    expect(c.read(dockerClientProvider)!.apiVersion, '1.45');
    expect(find.byType(HomeScreen), findsOneWidget);
  });

  testWidgets('a failed connect stays put and reports the error', (tester) async {
    final c = await pumpLauncher(tester, agent,
        FakeTransportFactory([const DockerError(DockerErrorKind.network, 'refused')]));
    await tester.pump();
    expect(find.byType(HomeScreen), findsNothing);
    expect(c.read(transportProvider), isNull);
    expect(find.textContaining('refused'), findsOneWidget);
  });

  testWidgets('SSH first use pins the presented key into the stored profile', (tester) async {
    final store = InMemoryProfileStore();
    await store.add(ssh());
    final d = FakeDaemon();
    await pumpLauncher(tester, ssh(), FakeTransportFactory([BuiltTransport(d.transport, presentedHostKey: 'FP-NEW')]),
        store: store);
    expect((await store.list()).single.ssh!.pinnedHostKey, 'FP-NEW');
  });

  testWidgets('SSH mismatch shows the dialog; Trust reconnects with the new key and re-pins', (tester) async {
    final store = InMemoryProfileStore();
    await store.add(ssh(pin: 'FP-OLD'));
    final d = FakeDaemon();
    final factory = FakeTransportFactory([
      const HostKeyMismatchException('FP-NEW'),
      BuiltTransport(d.transport, presentedHostKey: 'FP-NEW'),
    ]);
    await pumpLauncher(tester, ssh(pin: 'FP-OLD'), factory, store: store);
    await tester.pumpAndSettle();
    expect(find.text('Host key changed'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Trust new key'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(factory.pinOverrides, [null, 'FP-NEW']);
    expect((await store.list()).single.ssh!.pinnedHostKey, 'FP-NEW');
  });

  testWidgets('Cancel on the mismatch dialog leaves the pin alone', (tester) async {
    final store = InMemoryProfileStore();
    await store.add(ssh(pin: 'FP-OLD'));
    final factory = FakeTransportFactory([const HostKeyMismatchException('FP-NEW')]);
    await pumpLauncher(tester, ssh(pin: 'FP-OLD'), factory, store: store);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(factory.builds, 1);
    expect((await store.list()).single.ssh!.pinnedHostKey, 'FP-OLD');
  });
}
