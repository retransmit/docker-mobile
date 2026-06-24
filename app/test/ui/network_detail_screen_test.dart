import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/network_detail_screen.dart';

class _FakeTransport implements Transport {
  final List<String> deletes = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response(
        '{"Id":"n1","Name":"mynet","Driver":"bridge","Scope":"local","Internal":true,"IPAM":{"Driver":"default","Config":[{"Subnet":"10.0.0.0/24","Gateway":"10.0.0.1"}]},"Containers":{"abc":{"Name":"web","IPv4Address":"10.0.0.2/24"}},"Labels":{"env":"prod"}}',
        200,
      );
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('', 200);
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
                builder: (_) => const NetworkDetailScreen(networkId: 'n1', title: 'mynet'))),
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
  testWidgets('renders detail + connected containers and removes', (tester) async {
    final t = _FakeTransport();
    await _open(tester, t);

    expect(find.text('mynet'), findsOneWidget); // app bar title
    expect(find.textContaining('10.0.0.0/24'), findsWidgets); // subnet
    expect(find.textContaining('web'), findsWidgets); // connected container

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove')); // confirm
    await tester.pumpAndSettle();

    expect(t.deletes, contains('/networks/n1'));
    expect(find.text('open'), findsOneWidget); // popped back
  });
}
