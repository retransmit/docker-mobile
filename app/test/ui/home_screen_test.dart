import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/home_screen.dart';
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
}
