import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/images_screen.dart';

import '../support/fake_transport.dart';

FakeTransport imagesFake() => FakeTransport()
  ..onGet('/images/json',
      (_) => http.Response('[{"Id":"sha256:abc","RepoTags":["nginx:latest"],"Size":1048576,"Created":0}]', 200))
  ..onPost('/images/prune', (_) => http.Response('', 200));

void main() {
  testWidgets('lists images and confirms Prune', (tester) async {
    final t = imagesFake();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ImagesScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('nginx:latest'), findsOneWidget);
    expect(find.text('sha256:abc'), findsOneWidget); // short id mono subtitle
    expect(find.text('1.0 MB'), findsOneWidget); // size meta chip

    await tester.tap(find.byIcon(Icons.cleaning_services));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('confirming Prune calls pruneImages', (tester) async {
    final t = imagesFake();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ImagesScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.cleaning_services));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Dangling'));
    await tester.pumpAndSettle();

    expect(t.posts.map((c) => c.path), contains('/images/prune'));
    expect(find.textContaining('Pruned'), findsOneWidget); // success snackbar
  });
}
