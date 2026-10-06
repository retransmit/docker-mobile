import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/network_create_sheet.dart';

import '../support/fake_transport.dart';
import '../support/held_transport.dart';

/// Opens the sheet over a first route (and a second one, if asked), names the
/// network and taps Create; the create stays in flight until `release()`.
Future<HeldTransport> _startCreate(WidgetTester tester, {bool overSecondRoute = false}) async {
  final t = HeldTransport()..onPost('/networks/create', (_) => http.Response('{"Id":"n9"}', 201));
  final navigator = await pumpOverFirstRoute(
      tester, t, overSecondRoute ? const Scaffold(body: Text('second')) : const NetworkCreateSheet());
  if (overSecondRoute) {
    navigator.push(MaterialPageRoute<void>(builder: (_) => const NetworkCreateSheet()));
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.widgetWithText(TextField, 'Name'), 'mynet');
  await tester.pump();
  await tester.tap(find.widgetWithText(FilledButton, 'Create'));
  return t;
}

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

  testWidgets('a sheet closed underneath a pending create does not close the screen below', (tester) async {
    final t = await _startCreate(tester);
    popToFirstRoute(tester); // the sheet is on its way out, and still mounted until its transition ends
    t.release();
    await tester.pumpAndSettle();

    expect(t.posts.single.path, '/networks/create'); // the create did answer
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('backing out of the sheet during a pending create keeps the screen it was opened from', (tester) async {
    final t = await _startCreate(tester, overSecondRoute: true);
    tester.state<NavigatorState>(find.byType(Navigator)).pop(); // back
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100)); // the answer arrives during the exit transition
    t.release();
    await tester.pumpAndSettle();

    expect(t.posts.single.path, '/networks/create');
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('a finished create closes the sheet and the dropdown that is open on top of it', (tester) async {
    final t = await _startCreate(tester);
    await tester.pump();
    await tester.tap(find.byType(DropdownButton<String>)); // its menu is a route of its own
    await tester.pumpAndSettle();
    expect(find.text('overlay'), findsWidgets); // the menu is open

    t.release();
    await tester.pumpAndSettle();
    expect(find.text('overlay', skipOffstage: false), findsNothing);
    expect(find.byType(NetworkCreateSheet, skipOffstage: false), findsNothing);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('Network created'), findsOneWidget);
  });

  testWidgets('a create that answers after the sheet is gone reports no failure', (tester) async {
    final t = await _startCreate(tester);
    popToFirstRoute(tester);
    await tester.pumpAndSettle(); // the sheet is disposed by now
    t.release();
    await tester.pumpAndSettle();

    expect(t.posts.single.path, '/networks/create');
    expect(find.textContaining('Failed'), findsNothing);
    expect(find.text('first'), findsOneWidget);
  });
}
