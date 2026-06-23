import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/container_detail_screen.dart';

class _FakeTransport implements Transport {
  final String status; // container State.Status
  final bool running;
  final List<String> posts = [];
  final List<String> deletes = [];
  _FakeTransport({this.status = 'running', this.running = true});

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response(
        '{"Id":"a","Name":"/web","Config":{"Image":"nginx"},"State":{"Status":"$status","Running":$running,"Paused":false}}',
        200,
      );
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(path);
    return http.Response('', 204);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    deletes.add(path);
    return http.Response('', 204);
  }
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
}

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ContainerDetailScreen(containerId: 'a', containerName: 'web')),
    );

void main() {
  testWidgets('renders detail and a stopped container offers Start', (tester) async {
    final t = _FakeTransport(status: 'exited', running: false);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget); // app bar title
    expect(find.textContaining('nginx'), findsWidgets); // image shown
    expect(find.widgetWithText(ElevatedButton, 'Start'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Start'));
    await tester.pumpAndSettle();
    expect(t.posts, contains('/containers/a/start'));
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('Remove opens a confirmation dialog', (tester) async {
    final t = _FakeTransport(status: 'running', running: true);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Force'), findsOneWidget);
  });
}
