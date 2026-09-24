import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/create_container_screen.dart';

import '../support/fake_transport.dart';

FakeTransport createFake({int createStatus = 201}) {
  var status = createStatus;
  return FakeTransport()
    ..onGet('/networks', (_) => http.Response('[]', 200))
    ..onPost('/containers/abc/start', (_) => http.Response('', 204))
    ..onPost('/containers/create', (_) {
      // First call may 404 (image missing); later calls succeed.
      if (status == 404) {
        status = 201; // next create succeeds (post-pull)
        return http.Response('{"message":"No such image: nginx"}', 404);
      }
      return http.Response('{"Id":"abc"}', 201);
    })
    ..onPostStream(RegExp(r'/images/create'), (_) => Stream.value(utf8.encode('{"status":"Pull complete"}\n')));
}

Widget _wrap(Transport t, {String? image}) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: MaterialApp(home: CreateContainerScreen(image: image)),
    );

void main() {
  testWidgets('empty image blocks create', (tester) async {
    final t = createFake();
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pump();
    expect(find.textContaining('Image'), findsWidgets);
    expect(t.posts, isEmpty);
  });

  testWidgets('valid create (start on) posts create then start', (tester) async {
    final t = createFake();
    await tester.pumpWidget(_wrap(t, image: 'nginx'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(t.posts.map((p) => p.path), containsAllInOrder(<String>['/containers/create', '/containers/abc/start']));
  });

  testWidgets('404 offers to pull, then retries create', (tester) async {
    final t = createFake(createStatus: 404);
    await tester.pumpWidget(_wrap(t, image: 'nginx'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    // confirm the pull
    expect(find.textContaining('not found'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, 'Pull'));
    await tester.pumpAndSettle();
    // create was attempted twice (404 then 201)
    expect(t.posts.where((p) => p.path == '/containers/create').length, 2);
  });
}
