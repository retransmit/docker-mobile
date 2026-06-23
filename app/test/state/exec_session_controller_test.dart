import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/exec_session_controller.dart';

class _FakeExecChannel implements ExecChannel {
  final controller = StreamController<List<int>>();
  final sent = <List<int>>[];
  bool closed = false;
  @override
  Stream<List<int>> get output => controller.stream;
  @override
  void send(List<int> data) => sent.add(data);
  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) await controller.close();
  }
}

class _Post {
  final String path;
  final Map<String, String>? query;
  final Object? body;
  _Post(this.path, this.query, this.body);
}

class _ExecFakeTransport implements Transport {
  final List<_FakeExecChannel> channels = [];
  final List<_Post> posts = [];
  final int exitCode;
  final bool failCreate;
  _ExecFakeTransport({this.exitCode = 0, this.failCreate = false});

  _FakeExecChannel get lastChannel => channels.last;

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async =>
      http.Response('{"Running":false,"ExitCode":$exitCode}', 200);

  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(_Post(path, query, body));
    if (path.endsWith('/exec')) {
      return failCreate ? http.Response('boom', 500) : http.Response('{"Id":"e1"}', 201);
    }
    return http.Response('', 200); // resize
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async {
    final ch = _FakeExecChannel();
    channels.add(ch);
    return ch;
  }

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      throw UnimplementedError();
}

void main() {
  test('forwards terminal input to the channel', () async {
    final t = _ExecFakeTransport();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    expect(c.status, ExecStatus.connected);

    c.terminal.onOutput?.call('hi');
    expect(t.lastChannel.sent.map(utf8.decode).toList(), ['hi']);
    c.dispose();
  });

  test('status becomes ended with the exit code when output closes', () async {
    final t = _ExecFakeTransport(exitCode: 137);
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();

    await t.lastChannel.controller.close();
    await pumpEventQueue();

    expect(c.status, ExecStatus.ended);
    expect(c.exitCode, 137);
    c.dispose();
  });

  test('error status when exec creation fails', () async {
    final t = _ExecFakeTransport(failCreate: true);
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    expect(c.status, ExecStatus.error);
    c.dispose();
  });

  test('restart tears down the old session and starts a new one with the given command', () async {
    final t = _ExecFakeTransport();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    expect(t.channels, hasLength(1));

    await c.restart('top');
    await pumpEventQueue();

    expect(t.channels[0].closed, isTrue); // prior channel closed
    expect(t.channels, hasLength(2)); // new session attached
    expect(c.status, ExecStatus.connected);
    final createPosts = t.posts.where((p) => p.path.endsWith('/exec')).toList();
    expect((createPosts.last.body as Map)['Cmd'], ['/bin/sh', '-c', 'top']);
    c.dispose();
  });

  test('terminal resize is forwarded to resizeExec with h=rows, w=cols', () async {
    final t = _ExecFakeTransport();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();

    c.terminal.onResize?.call(120, 40, 0, 0); // (width=cols, height=rows, ...)
    await pumpEventQueue();

    final resize = t.posts.firstWhere((p) => p.path.endsWith('/resize'));
    expect(resize.path, '/exec/e1/resize');
    expect(resize.query, {'h': '40', 'w': '120'});
    c.dispose();
  });

  test('default command tries bash then falls back to sh', () async {
    final t = _ExecFakeTransport();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();

    final create = t.posts.firstWhere((p) => p.path.endsWith('/exec'));
    expect((create.body as Map)['Cmd'], [
      '/bin/sh',
      '-c',
      'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi',
    ]);
    c.dispose();
  });

  test('disposing during connect does not notify after dispose or leak the channel', () async {
    final t = _ExecFakeTransport();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    c.dispose(); // dispose while createExec/attachExec are still in flight
    await pumpEventQueue(); // let the in-flight futures resolve

    // A channel that resolved after dispose must have been closed, not leaked;
    // and the controller must not have called notifyListeners after dispose
    // (which would throw and fail this test).
    expect(t.channels.every((ch) => ch.closed), isTrue);
  });
}
