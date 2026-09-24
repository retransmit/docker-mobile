import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/containers_screen.dart';
import 'package:docker_mobile/src/ui/image_detail_screen.dart';
import 'package:docker_mobile/src/ui/create_container_screen.dart';

import '../support/fake_transport.dart';

FakeTransport entrypointsFake() => FakeTransport()
  ..onGet('/containers/json', (_) => http.Response('[]', 200))
  ..onGet('/networks', (_) => http.Response('[]', 200))
  ..onGet('/images/sha/json',
      (_) => http.Response('{"Architecture":"amd64","Os":"linux","Size":1,"Created":"2024","Config":{}}', 200))
  ..onGet('/images/sha/history', (_) => http.Response('[]', 200));

Widget _wrap(Widget child) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => entrypointsFake())],
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('Containers FAB opens the create screen', (tester) async {
    await tester.pumpWidget(_wrap(const ContainersScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(CreateContainerScreen), findsOneWidget);
  });

  testWidgets('Image Run opens the create screen pre-filled', (tester) async {
    await tester.pumpWidget(_wrap(const ImageDetailScreen(imageId: 'sha', title: 'nginx:latest')));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Run'));
    await tester.pumpAndSettle();
    expect(find.byType(CreateContainerScreen), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Image (e.g. nginx:latest)'), findsOneWidget);
    expect(find.text('nginx:latest'), findsWidgets); // pre-filled image
  });
}
