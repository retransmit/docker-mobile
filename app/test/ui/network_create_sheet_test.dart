import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/network_create_sheet.dart';

import '../support/fake_transport.dart';

void main() {
  testWidgets('fills the form and creates a network with subnet + label', (tester) async {
    Map<String, dynamic>? createBody;
    final t = FakeTransport()
      ..onPost('/networks/create', (call) {
        createBody = call.body as Map<String, dynamic>;
        return http.Response('{"Id":"n9"}', 201);
      });
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: NetworkCreateSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'mynet');

    // Add one IPAM subnet row.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add subnet'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Subnet (CIDR)'), '10.0.0.0/24');

    // Add one label via the Labels KeyValueEditor (first Add icon belongs to Labels).
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'key'), 'env');
    await tester.enterText(find.widgetWithText(TextField, 'value'), 'prod');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(createBody, isNotNull);
    expect(createBody!['Name'], 'mynet');
    expect(createBody!['IPAM']['Config'], [
      {'Subnet': '10.0.0.0/24'}
    ]);
    expect(createBody!['Labels'], {'env': 'prod'});
  });

  testWidgets('Create is disabled until a name is entered', (tester) async {
    final t = FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: NetworkCreateSheet()),
    ));
    await tester.pumpAndSettle();

    final btn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'));
    expect(btn.onPressed, isNull); // disabled
  });

  testWidgets('a failing create shows an error snackbar without crashing', (tester) async {
    final t = FakeTransport()..onPost('/networks/create', (_) => http.Response('{"Id":"n9"}', 500));
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: NetworkCreateSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'mynet');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Failed'), findsOneWidget);
  });
}
