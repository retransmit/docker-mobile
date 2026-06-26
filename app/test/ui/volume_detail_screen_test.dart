import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/volume_detail_screen.dart';

class _FakeTransport implements Transport {
  @override
  Future<void> close() async {}
  final List<String> deletes = [];
  final List<Map<String, String>?> deleteQueries = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response(
        '{"Name":"data","Driver":"local","Mountpoint":"/var/lib/docker/volumes/data/_data","Scope":"local","Labels":{"env":"prod"}}',
        200,
      );
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    deletes.add(path);
    deleteQueries.add(query);
    return http.Response('', 204);
  }
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

Future<void> _open(WidgetTester tester, Transport t) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [transportProvider.overrideWith((ref) => t)],
    child: MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(child: ElevatedButton(
            onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => const VolumeDetailScreen(volumeName: 'data'))),
            child: const Text('open'),
          )),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders detail and removes', (tester) async {
    final t = _FakeTransport();
    await _open(tester, t);

    expect(find.text('data'), findsOneWidget); // app bar title
    expect(find.textContaining('/var/lib/docker/volumes/data/_data'), findsWidgets);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove')); // confirm
    await tester.pumpAndSettle();

    expect(t.deletes, contains('/volumes/data'));
    expect(find.text('open'), findsOneWidget); // popped back
  });

  testWidgets('the Force switch sends force=true', (tester) async {
    final t = _FakeTransport();
    await _open(tester, t);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile)); // toggle Force on
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove')); // confirm
    await tester.pumpAndSettle();

    expect(t.deleteQueries.last, {'force': 'true'});
  });
}
