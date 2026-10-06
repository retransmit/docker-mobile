import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/volume_detail_screen.dart';

import '../support/fake_transport.dart';
import '../support/held_transport.dart';

FakeTransport volumeFake([FakeTransport? base]) => (base ?? FakeTransport())
  ..onGet('/volumes/data', (_) => http.Response(
        '{"Name":"data","Driver":"local","Mountpoint":"/var/lib/docker/volumes/data/_data","Scope":"local","Labels":{"env":"prod"}}',
        200,
      ))
  ..onDelete('/volumes/data', (_) => http.Response('', 204));

Future<void> _open(WidgetTester tester, Transport t) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [transportProvider.overrideWith((ref) => t)],
    child: MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(child: ElevatedButton(
            onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => const VolumeDetailScreen(volumeName: 'data'))),
            child: const Text('open'),
          )),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Opens the screen and confirms Remove; the delete stays in flight until `release()`.
Future<HeldTransport> _startRemove(WidgetTester tester) async {
  final t = HeldTransport();
  await _open(tester, volumeFake(t));
  await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(TextButton, 'Remove')); // confirm
  await tester.pumpAndSettle();
  return t;
}

void main() {
  testWidgets('renders detail and removes', (tester) async {
    final t = volumeFake();
    await _open(tester, t);

    expect(find.text('data'), findsOneWidget); // app bar title
    expect(find.textContaining('/var/lib/docker/volumes/data/_data'), findsWidgets);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove')); // confirm
    await tester.pumpAndSettle();

    expect(t.calls.where((c) => c.method == 'DELETE').map((c) => c.path), contains('/volumes/data'));
    expect(find.text('open'), findsOneWidget); // popped back
  });

  testWidgets('the Force switch sends force=true', (tester) async {
    final t = volumeFake();
    await _open(tester, t);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile)); // toggle Force on
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove')); // confirm
    await tester.pumpAndSettle();

    expect(t.calls.lastWhere((c) => c.method == 'DELETE').query, {'force': 'true'});
  });

  testWidgets('a screen closed underneath a pending remove does not close the screen below', (tester) async {
    final t = await _startRemove(tester);
    popToFirstRoute(tester); // the screen is on its way out, and still mounted until its transition ends
    t.release();
    await tester.pumpAndSettle();

    expect(t.calls.where((c) => c.method == 'DELETE'), hasLength(1)); // the remove did answer
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a remove that answers after the screen is gone reports no failure', (tester) async {
    final t = await _startRemove(tester);
    popToFirstRoute(tester);
    await tester.pumpAndSettle(); // the screen is disposed by now
    t.release();
    await tester.pumpAndSettle();

    expect(t.calls.where((c) => c.method == 'DELETE'), hasLength(1));
    expect(find.textContaining('Failed'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
