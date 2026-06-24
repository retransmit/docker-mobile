import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/pull_sheet.dart';

class _FakeTransport implements Transport {
  final List<int> pullBytes;
  Map<String, String>? lastPullQuery;
  _FakeTransport(this.pullBytes);
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
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
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) {
    lastPullQuery = query;
    return Stream.value(pullBytes);
  }
}

void main() {
  testWidgets('streams progress for a pulled ref', (tester) async {
    final t = _FakeTransport(utf8.encode('{"status":"Pulling fs layer","id":"l1"}\n{"status":"Pull complete","id":"l1"}\n'));
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: PullSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nginx:1.27');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Pull'));
    await tester.pumpAndSettle();

    expect(t.lastPullQuery, {'fromImage': 'nginx', 'tag': '1.27'});
    expect(find.textContaining('Pull complete'), findsWidgets);
  });

  testWidgets('surfaces an error event', (tester) async {
    final t = _FakeTransport(utf8.encode('{"error":"manifest unknown"}\n'));
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: PullSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Pull'));
    await tester.pumpAndSettle();

    expect(find.textContaining('manifest unknown'), findsOneWidget);
  });
}
