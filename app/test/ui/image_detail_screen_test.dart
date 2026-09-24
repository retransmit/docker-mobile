import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/image_detail_screen.dart';

import '../support/fake_transport.dart';

FakeTransport imageFake() => FakeTransport()
  ..onGet('/images/sha256:abc/json', (_) => http.Response(
        '{"Id":"sha256:abc","RepoTags":["nginx:latest"],"Architecture":"amd64","Os":"linux","Size":100,"Created":"2026-01-02T03:04:05Z","Config":{"Env":[],"ExposedPorts":{"80/tcp":{}}}}',
        200,
      ))
  ..onGet('/images/sha256:abc/history',
      (_) => http.Response('[{"Id":"l1","Created":0,"CreatedBy":"RUN apt-get","Size":10,"Tags":[]}]', 200))
  ..onPost('/images/sha256:abc/tag', (_) => http.Response('', 201))
  ..onDelete('/images/sha256:abc', (_) => http.Response('', 200));

/// Pushes ImageDetailScreen onto a base route so the screen's own Navigator.pop works.
Future<void> _open(WidgetTester tester, Transport t) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [transportProvider.overrideWith((ref) => t)],
    child: MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                  builder: (_) => const ImageDetailScreen(imageId: 'sha256:abc', title: 'nginx:latest'))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders inspect + history and offers Remove', (tester) async {
    await _open(tester, imageFake());

    expect(find.text('nginx:latest'), findsOneWidget); // app bar title
    expect(find.textContaining('amd64'), findsWidgets);
    expect(find.textContaining('RUN apt-get'), findsWidgets); // history layer
    expect(find.widgetWithText(ElevatedButton, 'Remove'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('confirming Remove deletes the image and pops back', (tester) async {
    final t = imageFake();
    await _open(tester, t);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove')); // dialog confirm
    await tester.pumpAndSettle();

    expect(t.calls.where((c) => c.method == 'DELETE').map((c) => c.path), contains('/images/sha256:abc'));
    expect(find.text('open'), findsOneWidget); // popped back to the base route
  });

  testWidgets('Tag dialog tags the image', (tester) async {
    final t = imageFake();
    await _open(tester, t);

    await tester.tap(find.widgetWithText(OutlinedButton, 'Tag'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'myrepo');
    await tester.tap(find.widgetWithText(TextButton, 'Tag')); // dialog confirm
    await tester.pumpAndSettle();

    expect(t.posts.map((c) => c.path), contains('/images/sha256:abc/tag'));
  });
}
