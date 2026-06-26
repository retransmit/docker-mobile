import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/containers_screen.dart';
import 'package:docker_mobile/src/ui/image_detail_screen.dart';
import 'package:docker_mobile/src/ui/create_container_screen.dart';

class _FakeTransport implements Transport {
  @override
  Future<void> close() async {}
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path.contains('/history')) return http.Response('[]', 200);
    if (path.startsWith('/images/')) {
      return http.Response('{"Architecture":"amd64","Os":"linux","Size":1,"Created":"2024","Config":{}}', 200);
    }
    return http.Response('[]', 200); // containers list, networks
  }
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async => http.Response('', 204);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

Widget _wrap(Widget child) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => _FakeTransport())],
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
