import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/home_screen.dart';

import '../support/fake_transport.dart';

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
}
