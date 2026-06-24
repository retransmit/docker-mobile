import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/image_detail_screen.dart';

class _FakeTransport implements Transport {
  final List<String> deletes = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path.endsWith('/history')) {
      return http.Response('[{"Id":"l1","Created":0,"CreatedBy":"RUN apt-get","Size":10,"Tags":[]}]', 200);
    }
    return http.Response('{"Id":"sha256:abc","RepoTags":["nginx:latest"],"Architecture":"amd64","Os":"linux","Size":100,"Created":"2026-01-02T03:04:05Z","Config":{"Env":[],"ExposedPorts":{"80/tcp":{}}}}', 200);
  }
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('', 201);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    deletes.add(path);
    return http.Response('', 200);
  }
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  testWidgets('renders inspect + history and offers Remove', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ImageDetailScreen(imageId: 'sha256:abc', title: 'nginx:latest')),
    ));
    await tester.pumpAndSettle();

    expect(find.text('nginx:latest'), findsOneWidget); // app bar title
    expect(find.textContaining('amd64'), findsWidgets);
    expect(find.textContaining('RUN apt-get'), findsWidgets); // history layer
    expect(find.widgetWithText(ElevatedButton, 'Remove'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  });
}
