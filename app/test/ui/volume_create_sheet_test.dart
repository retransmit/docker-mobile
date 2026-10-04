import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/volume_create_sheet.dart';

import '../support/fake_transport.dart';
import '../support/held_transport.dart';

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: VolumeCreateSheet()),
    );

/// Opens the sheet over a first route, names the volume and taps Create; the
/// create stays in flight until `release()`.
Future<HeldTransport> _startCreate(WidgetTester tester) async {
  final t = HeldTransport()
    ..onPost('/volumes/create', (_) => http.Response('{"Name":"data","Driver":"local"}', 201));
  await pumpOverFirstRoute(tester, t, const VolumeCreateSheet());
  await tester.enterText(find.widgetWithText(TextField, 'Name'), 'data');
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, 'Create'));
  return t;
}

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

  testWidgets('a sheet closed underneath a pending create does not close the screen below', (tester) async {
    final t = await _startCreate(tester);
    popToFirstRoute(tester); // the sheet is on its way out, and still mounted until its transition ends
    t.release();
    await tester.pumpAndSettle();

    expect(t.posts.single.path, '/volumes/create'); // the create did answer
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('a create that answers after the sheet is gone reports no failure', (tester) async {
    final t = await _startCreate(tester);
    popToFirstRoute(tester);
    await tester.pumpAndSettle(); // the sheet is disposed by now
    t.release();
    await tester.pumpAndSettle();

    expect(t.posts.single.path, '/volumes/create');
    expect(find.textContaining('Failed'), findsNothing);
    expect(find.text('first'), findsOneWidget);
  });
}
