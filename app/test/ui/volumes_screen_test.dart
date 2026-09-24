import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/volumes_screen.dart';

import '../support/fake_transport.dart';

FakeTransport volumesFake() => FakeTransport()
  ..onGet('/volumes',
      (_) => http.Response('{"Volumes":[{"Name":"data","Driver":"local","Mountpoint":"/mnt/data"}]}', 200))
  ..onPost('/volumes/prune', (_) => http.Response('', 200));

void main() {
  testWidgets('lists volumes and confirms Prune', (tester) async {
    final t = volumesFake();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: VolumesScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('data'), findsOneWidget);
    expect(find.text('/mnt/data'), findsOneWidget); // mountpoint mono subtitle
    expect(find.text('local'), findsOneWidget); // driver chip

    await tester.tap(find.byIcon(Icons.cleaning_services));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Prune'));
    await tester.pumpAndSettle();
    expect(t.posts.map((c) => c.path), contains('/volumes/prune'));
  });
}
