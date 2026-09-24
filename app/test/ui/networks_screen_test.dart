import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/networks_screen.dart';

import '../support/fake_transport.dart';

FakeTransport networksFake() => FakeTransport()
  ..onGet('/networks', (_) => http.Response('[{"Id":"n1","Name":"mynet","Driver":"bridge","Scope":"local"}]', 200))
  ..onPost('/networks/prune', (_) => http.Response('', 200));

void main() {
  testWidgets('lists networks and confirms Prune', (tester) async {
    final t = networksFake();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: NetworksScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('mynet'), findsOneWidget);
    expect(find.text('bridge'), findsOneWidget); // driver chip
    expect(find.text('local'), findsOneWidget); // scope chip

    await tester.tap(find.byIcon(Icons.cleaning_services));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Prune'));
    await tester.pumpAndSettle();
    expect(t.posts.map((c) => c.path), contains('/networks/prune'));
  });
}
