import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/volume_detail_screen.dart';

import '../support/fake_transport.dart';

FakeTransport volumeFake() => FakeTransport()
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
}
