import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/create_container_screen.dart';

import '../support/fake_transport.dart';
import '../support/held_transport.dart';

FakeTransport createFake({int createStatus = 201, FakeTransport? base}) {
  var status = createStatus;
  return (base ?? FakeTransport())
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

  testWidgets('a screen closed underneath a pending create does not close the screen below', (tester) async {
    final t = HeldTransport();
    await pumpOverFirstRoute(tester, createFake(base: t), const CreateContainerScreen(image: 'nginx'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create')); // the create is now in flight

    popToFirstRoute(tester); // the screen is on its way out, and still mounted until its transition ends
    t.release();
    await tester.pumpAndSettle();

    expect(t.posts.map((p) => p.path), contains('/containers/create')); // the create did answer
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('a screen that was closed during the create shows no "Image not found" dialog', (tester) async {
    final t = HeldTransport();
    await pumpOverFirstRoute(
        tester, createFake(createStatus: 404, base: t), const CreateContainerScreen(image: 'nginx'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create')); // the create is now in flight

    popToFirstRoute(tester);
    t.release(); // the daemon answers 404: the image is missing
    await tester.pumpAndSettle();

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text('Image not found'), findsNothing);
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('a pull dialog closed underneath does not close the screen below when its stream ends', (tester) async {
    final pull = StreamController<List<int>>(); // a pull that stays open
    final t = createFake(createStatus: 404)..onPostStream(RegExp(r'/images/create'), (_) => pull.stream);
    await pumpOverFirstRoute(tester, t, const CreateContainerScreen(image: 'nginx'));
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Pull'));
    // The dialog's spinner never settles: pump its transition by hand.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('Pulling image'), findsOneWidget);

    popToFirstRoute(tester); // dialog and screen are on their way out, still mounted
    unawaited(pull.close()); // the pull ends, as it does when the transport is closed
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Pulling image'), findsNothing);
    expect(find.text('first'), findsOneWidget);
  });
}
