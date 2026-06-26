import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/connect/disconnect.dart';

class _FakeTransport implements Transport {
  bool closed = false;
  @override
  Future<void> close() async => closed = true;
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async => http.Response('', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  testWidgets('disconnect pops to the first route, nulls and closes the transport', (tester) async {
    final fake = _FakeTransport();
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => fake)],
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          container = ProviderScope.containerOf(ctx);
          return Scaffold(
            body: Center(child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => Consumer(builder: (c, ref, _) => Scaffold(
                  body: Center(child: ElevatedButton(
                    onPressed: () => disconnect(c, ref),
                    child: const Text('disconnect'),
                  )),
                )),
              )),
              child: const Text('go'),
            )),
          );
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('disconnect'));
    await tester.pumpAndSettle();

    expect(container.read(transportProvider), isNull);
    expect(fake.closed, isTrue);
    expect(find.text('go'), findsOneWidget); // back on the first route
    expect(find.text('disconnect'), findsNothing);
  });
}
