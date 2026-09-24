import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/volume_create_sheet.dart';

import '../support/fake_transport.dart';

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: VolumeCreateSheet()),
    );

void main() {
  testWidgets('fills the form and creates a volume with a label', (tester) async {
    Map<String, dynamic>? createBody;
    final t = FakeTransport()
      ..onPost('/volumes/create', (call) {
        createBody = call.body as Map<String, dynamic>;
        return http.Response('{"Name":"data","Driver":"local"}', 201);
      });
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'data');
    await tester.tap(find.byIcon(Icons.add).first); // Labels editor
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'key'), 'env');
    await tester.enterText(find.widgetWithText(TextField, 'value'), 'prod');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(createBody, isNotNull);
    expect(createBody!['Name'], 'data');
    expect(createBody!['Driver'], 'local');
    expect(createBody!['Labels'], {'env': 'prod'});
  });

  testWidgets('Create is disabled until a name is entered', (tester) async {
    await tester.pumpWidget(_wrap(FakeTransport()));
    await tester.pumpAndSettle();
    final btn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'));
    expect(btn.onPressed, isNull);
  });

  testWidgets('a failing create shows an error snackbar without crashing', (tester) async {
    final t = FakeTransport()
      ..onPost('/volumes/create', (_) => http.Response('{"Name":"data","Driver":"local"}', 500));
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'data');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed'), findsOneWidget);
  });
}
