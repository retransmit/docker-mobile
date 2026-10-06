import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/home_screen.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';
import 'package:docker_mobile/src/ui/widgets/session_banner.dart';

import '../support/fake_transport.dart';
import '../support/stub_session.dart';

FakeTransport homeFake() => FakeTransport()
  ..onGet('/containers/json', (_) => http.Response('[]', 200))
  ..onGet('/images/json', (_) => http.Response('[]', 200))
  ..onGet('/networks', (_) => http.Response('[]', 200))
  ..onGet('/volumes', (_) => http.Response('[]', 200))
  ..onGet('/info', (_) => http.Response('{}', 200))
  ..onGet('/version', (_) => http.Response('{}', 200))
  ..onGet('/system/df', (_) => http.Response('{}', 200));

/// How often [t] was asked for each of the dashboard's three endpoints.
Map<String, int> dashboardCalls(FakeTransport t) => {
      for (final path in const ['/info', '/version', '/system/df']) path: t.calls.where((c) => c.path == path).length,
    };

/// [dashboardCalls] when the dashboard was fetched [times] times.
Map<String, int> dashboardFetched(int times) => {'/info': times, '/version': times, '/system/df': times};

/// Home over a daemon that reports version 27.0.3, with the Containers tab
/// showing. Returns the transport and the container that owns the providers.
Future<(FakeTransport, ProviderContainer)> pumpHome(WidgetTester tester) async {
  final t = homeFake()..onGet('/info', (_) => http.Response('{"ServerVersion":"27.0.3"}', 200));
  await tester.pumpWidget(ProviderScope(
    overrides: [transportProvider.overrideWith((ref) => t)],
    child: const MaterialApp(home: HomeScreen()),
  ));
  await tester.pumpAndSettle();
  return (t, ProviderScope.containerOf(tester.element(find.byType(HomeScreen))));
}

/// Switches Home to the tab whose destination shows [icon].
Future<void> openTab(WidgetTester tester, IconData icon) async {
  await tester.tap(find.byIcon(icon));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the bottom nav switches the selected tab index', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => homeFake())],
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pumpAndSettle();

    NavigationBar bar() => tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar().selectedIndex, 0); // Containers

    await tester.tap(find.byIcon(Icons.layers)); // Images destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 1);

    await tester.tap(find.byIcon(Icons.hub)); // Networks destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 2);

    await tester.tap(find.byIcon(Icons.storage)); // Volumes destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 3);

    await tester.tap(find.byIcon(Icons.monitor_heart)); // System destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 4);

    await tester.tap(find.byIcon(Icons.inventory)); // Containers destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 0);
  });

  testWidgets('Home hosts no session banner of its own, even while reconnecting', (tester) async {
    final stub = StubSession(const SessionState(status: SessionStatus.reconnecting, attempt: 1));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        transportProvider.overrideWith((ref) => homeFake()),
        sessionProvider.overrideWith((ref) => stub),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pump(const Duration(milliseconds: 500));
    // The app shell shows it above every route (see SessionBannerHost).
    expect(find.byType(SessionBanner), findsNothing);
    expect(find.textContaining('Reconnecting'), findsNothing);
  });

  testWidgets('an old-daemon warning shows once and is acknowledged', (tester) async {
    final stub = StubSession(const SessionState(status: SessionStatus.connected, warning: 'This daemon speaks Docker API 1.40.'));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        transportProvider.overrideWith((ref) => homeFake()),
        sessionProvider.overrideWith((ref) => stub),
      ],
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('This daemon speaks Docker API 1.40.'), findsOneWidget);
    expect(stub.acknowledged, 1);
  });

  group('the dashboard', () {
    testWidgets('is not fetched while another tab shows, not even when a refresh of it is due', (tester) async {
      final (t, container) = await pumpHome(tester);
      expect(dashboardCalls(t), dashboardFetched(0));
      expect(find.byType(StatCard, skipOffstage: false), findsNothing);

      // What daemon events and a reconnect do to it.
      container.invalidate(systemDashboardProvider);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(dashboardCalls(t), dashboardFetched(0));

      // The other tabs do not wake it either.
      for (final icon in [Icons.layers, Icons.hub, Icons.storage]) {
        await openTab(tester, icon);
        expect(dashboardCalls(t), dashboardFetched(0), reason: '$icon');
      }
    });

    testWidgets('is fetched once when the System tab is opened, and shown', (tester) async {
      final (t, _) = await pumpHome(tester);
      expect(dashboardCalls(t), dashboardFetched(0));

      await openTab(tester, Icons.monitor_heart);
      expect(dashboardCalls(t), dashboardFetched(1));
      expect(find.byType(StatCard), findsNWidgets(4));
      expect(find.text('27.0.3'), findsOneWidget);
    });

    testWidgets('is not refetched by leaving the tab and returning; a refresh that came due meanwhile runs on return',
        (tester) async {
      final (t, container) = await pumpHome(tester);
      await openTab(tester, Icons.monitor_heart);
      expect(dashboardCalls(t), dashboardFetched(1));

      await openTab(tester, Icons.inventory);
      await openTab(tester, Icons.monitor_heart);
      expect(dashboardCalls(t), dashboardFetched(1));
      expect(find.text('27.0.3'), findsOneWidget);

      await openTab(tester, Icons.inventory);
      container.invalidate(systemDashboardProvider);
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(dashboardCalls(t), dashboardFetched(1)); // not while the tab is hidden

      await openTab(tester, Icons.monitor_heart);
      expect(dashboardCalls(t), dashboardFetched(2));
      expect(find.text('27.0.3'), findsOneWidget);
    });
  });
}
