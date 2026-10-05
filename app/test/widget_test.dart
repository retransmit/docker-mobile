import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/main.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/session/reconnect_policy.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/state/theme_provider.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/storage/settings_store.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/ui/home_screen.dart';
import 'package:docker_mobile/src/ui/profiles_screen.dart';
import 'package:docker_mobile/src/ui/settings_screen.dart';
import 'package:docker_mobile/src/ui/widgets/error_view.dart';
import 'package:docker_mobile/src/ui/widgets/session_banner.dart';
import 'package:docker_mobile/src/ui/widgets/skeletons.dart';

import 'support/fake_session.dart';
import 'support/stub_session.dart';

/// Boots the whole app on in-memory stores (see the boot test), plus
/// [overrides]. The saved connections are those in [profiles], if given.
Future<void> _pumpApp(WidgetTester tester, {ProfileStore? profiles, List<Override> overrides = const []}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profileStoreProvider.overrideWithValue(profiles ?? InMemoryProfileStore()),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        ...overrides,
      ],
      child: const DockerMobileApp(),
    ),
  );
  await tester.pumpAndSettle();
}

/// A daemon that answers everything Home asks for and lists [containers] by name.
FakeDaemon _daemon(List<String> containers) {
  final list = [
    for (final name in containers) '{"Id":"$name","Names":["/$name"],"Image":"nginx","State":"running","Status":"Up"}',
  ].join(',');
  final d = FakeDaemon();
  d.transport
    ..onGet(RegExp(r'/containers/json$'), (_) => http.Response('[$list]', 200))
    ..onGet(RegExp(r'/images/json$'), (_) => http.Response('[]', 200))
    ..onGet(RegExp(r'/networks$'), (_) => http.Response('[]', 200))
    ..onGet(RegExp(r'/volumes$'), (_) => http.Response('{"Volumes":[]}', 200))
    ..onGet(RegExp(r'/info$'), (_) => http.Response('{}', 200))
    ..onGet(RegExp(r'/system/df$'), (_) => http.Response('{}', 200));
  return d;
}

void main() {
  testWidgets('app boots to the profiles screen', (tester) async {
    // Override the stores with in-memory fakes so the boot test never touches
    // real platform secure storage (which would hang the loading spinner and,
    // for settings, surface a MissingPluginException as an uncaught async error).
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileStoreProvider.overrideWithValue(InMemoryProfileStore()),
          settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        ],
        child: const DockerMobileApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProfilesScreen), findsOneWidget);
  });

  testWidgets('the app puts the session banner host above its routes', (tester) async {
    await _pumpApp(tester);
    expect(find.byType(SessionBannerHost), findsOneWidget);
    // Above the navigator: the first route (and so every route) sits inside it.
    expect(
      find.ancestor(of: find.byType(ProfilesScreen), matching: find.byType(SessionBannerHost)),
      findsOneWidget,
    );
  });

  testWidgets('the app banner disconnects through the app navigator', (tester) async {
    final stub = StubSession(const SessionState(status: SessionStatus.failed));
    await _pumpApp(tester, overrides: [sessionProvider.overrideWith((ref) => stub)]);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Retry').hitTestable(), findsOneWidget); // still there over a pushed route

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(ProfilesScreen), findsOneWidget);
    expect(stub.disconnects, 1);
  });

  testWidgets('the app banner offers Disconnect while it is still reconnecting', (tester) async {
    final stub = StubSession(const SessionState(status: SessionStatus.failed));
    await _pumpApp(tester, overrides: [sessionProvider.overrideWith((ref) => stub)]);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);

    // Retry puts the session back to reconnecting; its spinner never settles, so pump by hand from here.
    stub.setState(const SessionState(status: SessionStatus.reconnecting, attempt: 1));
    await tester.pump();
    expect(find.text('Retry'), findsNothing);
    await tester.tap(find.text('Disconnect'));
    await tester.pump(); // the pop starts
    await tester.pump(const Duration(milliseconds: 600)); // and ends
    await tester.pump(); // the navigator drops the popped route
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(ProfilesScreen), findsOneWidget);
    expect(stub.disconnects, 1);
  });

  testWidgets('connect, lose the connection, get it back and leave: the whole app over a real session',
      (tester) async {
    const alpha = ConnectionProfile(
        id: 'a', name: 'Alpha', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://a:1', token: 't'));
    final store = InMemoryProfileStore();
    await store.add(alpha);
    final d1 = _daemon(['web']);
    final d2 = _daemon(['web', 'db']); // a container was created while the connection was down
    final handshake = Completer<Transport>(); // the reconnect's, answered only when the test says so
    final factory = FakeTransportFactory([d1.transport, handshake.future]);
    await _pumpApp(tester, profiles: store, overrides: [
      transportFactoryProvider.overrideWithValue(factory),
      reconnectPolicyProvider.overrideWithValue(ReconnectPolicy(jitter: 0)),
      lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
    ]);
    final container = ProviderScope.containerOf(tester.element(find.byType(ProfilesScreen)));
    SessionState session() => container.read(sessionProvider);
    int listFetches(FakeDaemon d) => d.transport.calls.where((c) => c.path.endsWith('/containers/json')).length;
    // Home is as it was: the list is up and no tab, shown or not, fell back to a skeleton or an error.
    void expectHomeUntouched() {
      expect(find.text('/web'), findsOneWidget);
      expect(find.byType(SkeletonList, skipOffstage: false), findsNothing);
      expect(find.byType(SkeletonCards, skipOffstage: false), findsNothing);
      expect(find.byType(ErrorView, skipOffstage: false), findsNothing);
    }

    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(session().status, SessionStatus.connected);
    expectHomeUntouched();
    expect(find.text('/db'), findsNothing);

    // The connection drops. The reconnect banner shows over Home, which stays as it is.
    d1.events.addError(const DockerError(DockerErrorKind.network, 'reset'));
    await tester.pump(); // the session notices
    await tester.pump(); // and the banner is drawn
    expect(session().status, SessionStatus.reconnecting);
    expect(find.text('Reconnecting... (attempt 1 of 5)'), findsOneWidget);
    expectHomeUntouched();

    // The first attempt starts after a second, and its handshake does not answer yet.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump(const Duration(milliseconds: 400)); // long enough for a switch to a skeleton, had one started
    expect(factory.builds, 2);
    expect(find.text('Reconnecting... (attempt 1 of 5)'), findsOneWidget);
    expectHomeUntouched();
    expect(listFetches(d1), 1); // nothing was asked of the dead connection

    // The handshake answers: the banner goes and the list is refreshed over the new transport.
    handshake.complete(d2.transport);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(session().status, SessionStatus.connected);
    expect(session().transport, same(d2.transport));
    expect(d1.transport.closed, isTrue);
    expect(find.textContaining('Reconnecting'), findsNothing);
    expect(find.text('/db'), findsOneWidget);
    expectHomeUntouched();
    expect(listFetches(d1), 1);
    // What the reconnect cost: the probe, the events stream and one fetch of each list. The
    // dashboard, whose tab is hidden, was not asked for.
    expect(
      d2.transport.calls.map((c) => '${c.method} ${c.path}'),
      unorderedEquals([
        'GET /_ping',
        'GET /version',
        'STREAM /v1.45/events',
        'GET /v1.45/containers/json',
        'GET /v1.45/images/json',
        'GET /v1.45/networks',
        'GET /v1.45/volumes',
      ]),
    );

    // Back: the Connections list shows again and the session is over.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsNothing);
    expect(find.byType(ProfilesScreen), findsOneWidget);
    expect(find.text('Alpha'), findsOneWidget);
    expect(session().status, SessionStatus.disconnected);
    expect(session().error, isNull);
    expect(d2.transport.closed, isTrue);
    expect(d2.activeEventStreams, 0);
  });
}
