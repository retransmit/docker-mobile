import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/logs_screen.dart';

List<int> frame(int type, List<int> p) {
  final n = p.length;
  return [type, 0, 0, 0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, ...p];
}

class _FakeTransport implements Transport {
  final List<int>? logBytes;
  _FakeTransport({this.logBytes});

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response(
        '{"Id":"a","Name":"/web","Config":{"Image":"nginx","Tty":false},"State":{"Status":"running"}}',
        200,
      );

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    final bytes = logBytes ??
        [...frame(1, utf8.encode('hello-out\n')), ...frame(2, utf8.encode('oops-err\n'))];
    return Stream.value(bytes);
  }

  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) =>
      throw UnimplementedError();

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      throw UnimplementedError();
}

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: LogsScreen(containerId: 'a', containerName: 'web')),
    );

void main() {
  testWidgets('renders streamed log lines', (tester) async {
    await tester.pumpWidget(_wrap(_FakeTransport()));
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget); // app bar title
    expect(find.textContaining('hello-out', findRichText: true), findsOneWidget);
    expect(find.textContaining('oops-err', findRichText: true), findsOneWidget);
  });

  testWidgets('search filters the rendered lines', (tester) async {
    await tester.pumpWidget(_wrap(_FakeTransport()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'oops');
    await tester.pumpAndSettle();

    expect(find.textContaining('oops-err', findRichText: true), findsOneWidget);
    expect(find.textContaining('hello-out', findRichText: true), findsNothing);
  });

  testWidgets('jump-to-latest FAB appears when scrolled up', (tester) async {
    final many = '${List.generate(200, (i) => 'line$i').join('\n')}\n';
    await tester.pumpWidget(_wrap(_FakeTransport(logBytes: frame(1, utf8.encode(many)))));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_downward), findsNothing); // at bottom
    await tester.drag(find.byType(ListView), const Offset(0, 400)); // scroll toward top
    await tester.pump();

    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
  });
}
