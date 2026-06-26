import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/images_screen.dart';

class _FakeTransport implements Transport {
  @override
  Future<void> close() async {}
  final List<String> posts = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async =>
      http.Response('[{"Id":"sha256:abc","RepoTags":["nginx:latest"],"Size":1048576,"Created":0}]', 200);
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(path);
    return http.Response('', 200);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 200);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  testWidgets('lists images and confirms Prune', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ImagesScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.text('nginx:latest'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.cleaning_services));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });

  testWidgets('confirming Prune calls pruneImages', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ImagesScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.cleaning_services));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Dangling'));
    await tester.pumpAndSettle();

    expect(t.posts, contains('/images/prune'));
    expect(find.textContaining('Pruned'), findsOneWidget); // success snackbar
  });
}
