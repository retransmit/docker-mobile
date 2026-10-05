import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/connect/connection_launcher.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/session/transport_factory.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/home_screen.dart';
import 'package:docker_mobile/src/ui/widgets/session_banner.dart';

import '../support/fake_session.dart';
import '../support/fake_transport.dart';

const agent = ConnectionProfile(id: '1', name: 'A', kind: ConnectionKind.agent,
    agent: AgentCredentials(baseUri: 'http://127.0.0.1:8080', token: 't'));
ConnectionProfile ssh({String? pin}) => ConnectionProfile(id: '9', name: 'S', kind: ConnectionKind.ssh,
    ssh: SshCredentials(host: '127.0.0.1', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p', pinnedHostKey: pin));

/// A daemon's transport that counts how often it is closed. Its events
/// stream stays open until the test breaks it through [events].
class _CountingTransport extends FakeTransport {
  _CountingTransport() {
    onGet('/_ping', (_) => http.Response('OK', 200));
    onGet('/version', (_) => http.Response('{"Version":"27.0","ApiVersion":"1.46"}', 200));
    onStream(RegExp(r'/events$'), (_) => events.stream);
  }

  final events = StreamController<List<int>>();
  int closes = 0;

  @override
  Future<void> close() {
    closes++;
    return super.close();
  }
}

/// Taps a button that launches a connection to [p]. With [bannerOver], the
/// session banner sits above that navigator, as it does in the app.
Future<ProviderContainer> pumpLauncher(WidgetTester tester, ConnectionProfile p, FakeTransportFactory factory,
    {ProfileStore? store, GlobalKey<NavigatorState>? bannerOver}) async {
  late ProviderContainer container;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      profileStoreProvider.overrideWithValue(store ?? InMemoryProfileStore()),
      transportFactoryProvider.overrideWithValue(factory),
      lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
    ],
    child: MaterialApp(
      navigatorKey: bannerOver,
      builder: bannerOver == null
          ? null
          : (context, child) => SessionBannerHost(navigatorKey: bannerOver, child: child!),
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
    // No snackbar: the Connections screen shows the session's error inline.
    expect(find.byType(SnackBar), findsNothing);
    expect(c.read(sessionProvider).error!.message, 'refused');
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
    expect(find.byType(HomeScreen), findsOneWidget); // the trusted connect opens Home like any other
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

  /// The session is over and its one transport was closed, exactly once.
  void expectEnded(ProviderContainer c, _CountingTransport t, FakeTransportFactory factory) {
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.text('go'), findsOneWidget);
    final session = c.read(sessionProvider);
    expect(session.status, SessionStatus.disconnected);
    expect(session.error, isNull);
    expect(session.transport, isNull);
    expect(t.closes, 1);
    expect(t.events.hasListener, isFalse);
    expect(factory.builds, 1);
  }

  testWidgets('leaving Home ends the session', (tester) async {
    final t = _CountingTransport();
    final factory = FakeTransportFactory([t]);
    final c = await pumpLauncher(tester, agent, factory);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(c.read(sessionProvider).status, SessionStatus.connected);

    await tester.pageBack(); // the arrow in the tab's app bar
    await tester.pumpAndSettle();
    expectEnded(c, t, factory);
  });

  testWidgets('the Disconnect action on Home still ends the session once, without an error', (tester) async {
    final t = _CountingTransport();
    final factory = FakeTransportFactory([t]);
    final c = await pumpLauncher(tester, agent, factory);
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byIcon(Icons.monitor_heart)); // the System tab
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
    await tester.pumpAndSettle();
    expectEnded(c, t, factory);
  });

  testWidgets('Disconnect in the banner over Home still ends the session once, without an error', (tester) async {
    final t = _CountingTransport();
    final factory = FakeTransportFactory([t]);
    final c = await pumpLauncher(tester, agent, factory, bannerOver: GlobalKey<NavigatorState>());
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(HomeScreen), findsOneWidget);

    t.events.addError(const DockerError(DockerErrorKind.network, 'reset'));
    await tester.pump(); // the session notices
    await tester.pump(); // and the banner is drawn
    expect(c.read(sessionProvider).status, SessionStatus.reconnecting);

    await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
    await tester.pump(); // the banner and its spinner go
    await tester.pumpAndSettle();
    expectEnded(c, t, factory);
  });
}
