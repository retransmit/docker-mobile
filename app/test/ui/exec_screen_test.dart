import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:xterm/xterm.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/exec_screen.dart';

class _FakeExecChannel implements ExecChannel {
  final controller = StreamController<List<int>>();
  @override
  Stream<List<int>> get output => controller.stream;
  @override
  void send(List<int> data) {}
  @override
  Future<void> close() => controller.close();
}

class _FakeTransport implements Transport {
  final _FakeExecChannel channel;
  _FakeTransport(this.channel);
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async =>
      http.Response('{"Running":false,"ExitCode":0}', 200);
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('{"Id":"e1"}', 201);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async => channel;
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      throw UnimplementedError();
}

void main() {
  testWidgets('renders the terminal and command bar, then shows session ended', (tester) async {
    final ch = _FakeExecChannel();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [transportProvider.overrideWith((ref) => _FakeTransport(ch))],
        child: const MaterialApp(home: ExecScreen(containerId: 'a', containerName: 'web')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget); // app bar title
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); // command bar

    await ch.controller.close(); // process exits
    await tester.pumpAndSettle();
    expect(find.textContaining('ended'), findsOneWidget);
  });
}
