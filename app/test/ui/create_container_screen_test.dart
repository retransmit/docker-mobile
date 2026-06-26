import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/create_container_screen.dart';

class _FakeTransport implements Transport {
  final List<String> posts = [];
  int createStatus = 201;
  List<int> pullBytes = utf8.encode('{"status":"Pull complete"}\n');
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(path);
    if (path == '/containers/create') {
      // First call may 404 (image missing); later calls succeed.
      final status = createStatus;
      if (status == 404) createStatus = 201; // next create succeeds (post-pull)
      if (status == 404) return http.Response('{"message":"No such image: nginx"}', 404);
      return http.Response('{"Id":"abc"}', 201);
    }
    return http.Response('', 204);
  }
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => Stream.value(pullBytes);
}

Widget _wrap(Transport t, {String? image}) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: MaterialApp(home: CreateContainerScreen(image: image)),
    );

void main() {
  testWidgets('empty image blocks create', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pump();
    expect(find.textContaining('Image'), findsWidgets);
    expect(t.posts, isEmpty);
  });

  testWidgets('valid create (start on) posts create then start', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(_wrap(t, image: 'nginx'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(t.posts, containsAllInOrder(<String>['/containers/create', '/containers/abc/start']));
  });

  testWidgets('404 offers to pull, then retries create', (tester) async {
    final t = _FakeTransport()..createStatus = 404;
    await tester.pumpWidget(_wrap(t, image: 'nginx'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    // confirm the pull
    expect(find.textContaining('not found'), findsWidgets);
    await tester.tap(find.widgetWithText(TextButton, 'Pull'));
    await tester.pumpAndSettle();
    // create was attempted twice (404 then 201)
    expect(t.posts.where((p) => p == '/containers/create').length, 2);
  });
}
