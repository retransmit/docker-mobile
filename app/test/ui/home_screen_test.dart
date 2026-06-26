import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/home_screen.dart';

class _FakeTransport implements Transport {
  @override
  Future<void> close() async {}
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path == '/info') return http.Response('{}', 200);
    if (path == '/version') return http.Response('{}', 200);
    if (path == '/system/df') return http.Response('{}', 200);
    return http.Response('[]', 200);
  }
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('', 200);
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
  testWidgets('the bottom nav switches the selected tab index', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => _FakeTransport())],
      child: const MaterialApp(home: HomeScreen()),
    ));
    await tester.pumpAndSettle();

    NavigationBar bar() => tester.widget<NavigationBar>(find.byType(NavigationBar));
    expect(bar().selectedIndex, 0); // Containers

    await tester.tap(find.byIcon(Icons.layers)); // Images destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 1);

    await tester.tap(find.byIcon(Icons.hub)); // Networks destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 2);

    await tester.tap(find.byIcon(Icons.storage)); // Volumes destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 3);

    await tester.tap(find.byIcon(Icons.monitor_heart)); // System destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 4);

    await tester.tap(find.byIcon(Icons.inventory)); // Containers destination
    await tester.pumpAndSettle();
    expect(bar().selectedIndex, 0);
  });
}
