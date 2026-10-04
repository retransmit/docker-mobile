import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/exec_session_controller.dart';

import '../support/fake_transport.dart';

FakeTransport execFake({int exitCode = 0, bool failCreate = false}) => FakeTransport()
  ..onGet(RegExp(r'/exec/[^/]+/json$'), (_) => http.Response('{"Running":false,"ExitCode":$exitCode}', 200))
  ..onPost(RegExp(r'/exec$'), (_) => failCreate ? http.Response('boom', 500) : http.Response('{"Id":"e1"}', 201))
  ..onPost(RegExp(r'/resize$'), (_) => http.Response('', 200));

void main() {
  test('forwards terminal input to the channel', () async {
    final t = execFake();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    expect(c.status, ExecStatus.connected);

    c.terminal.onOutput?.call('hi');
    expect(t.lastChannel.sent.map(utf8.decode).toList(), ['hi']);
    c.dispose();
  });

  test('status becomes ended with the exit code when output closes', () async {
    final t = execFake(exitCode: 137);
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();

    await t.lastChannel.controller.close();
    await pumpEventQueue();

    expect(c.status, ExecStatus.ended);
    expect(c.exitCode, 137);
    c.dispose();
  });

  test('error status when exec creation fails', () async {
    final t = execFake(failCreate: true);
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    expect(c.status, ExecStatus.error);
    c.dispose();
  });

  test('restart tears down the old session and starts a new one with the given command', () async {
    final t = execFake();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    expect(t.execChannels, hasLength(1));

    await c.restart('top');
    await pumpEventQueue();

    expect(t.execChannels[0].closed, isTrue); // prior channel closed
    expect(t.execChannels, hasLength(2)); // new session attached
    expect(c.status, ExecStatus.connected);
    final createPosts = t.posts.where((p) => p.path.endsWith('/exec')).toList();
    expect((createPosts.last.body as Map)['Cmd'], ['/bin/sh', '-c', 'top']);
    c.dispose();
  });

  test('terminal resize is forwarded to resizeExec with h=rows, w=cols', () async {
    final t = execFake();
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
    final t = execFake();
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
    final t = execFake();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    c.dispose(); // dispose while createExec/attachExec are still in flight
    await pumpEventQueue(); // let the in-flight futures resolve

    // A channel that resolved after dispose must have been closed, not leaked;
    // and the controller must not have called notifyListeners after dispose
    // (which would throw and fail this test).
    expect(t.execChannels.every((ch) => ch.closed), isTrue);
  });

  test('end() marks the session ended and closes the channel without inspecting it', () async {
    final fake = execFake();
    final c = ExecSessionController(DockerApiClient(fake), 'web');
    await pumpEventQueue();
    expect(c.status, ExecStatus.connected);
    final inspectsBefore = fake.calls.where((x) => x.path.endsWith('/json')).length;
    await c.end();
    expect(c.status, ExecStatus.ended);
    expect(c.exitCode, isNull);
    expect(fake.lastChannel.closed, isTrue);
    await pumpEventQueue();
    expect(fake.calls.where((x) => x.path.endsWith('/json')).length, inspectsBefore);
    c.dispose();
  });

  test('a starting command is used for the first exec', () async {
    final t = execFake();
    final c = ExecSessionController(DockerApiClient(t), 'cid', command: 'top');
    await pumpEventQueue();

    final createPosts = t.posts.where((p) => p.path.endsWith('/exec')).toList();
    expect(createPosts, hasLength(1));
    expect((createPosts.single.body as Map)['Cmd'], ['/bin/sh', '-c', 'top']);
    expect(t.execChannels, hasLength(1));
    c.dispose();
  });

  test('end() while connecting stays ended and leaves no open channel', () async {
    final t = execFake();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    unawaited(c.end()); // the handshake is still in flight
    await pumpEventQueue();

    expect(c.status, ExecStatus.ended);
    expect(t.execChannels.where((ch) => !ch.closed), isEmpty);
    c.dispose();
  });

  test('restart while connecting leaves exactly one live channel', () async {
    final t = execFake();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    unawaited(c.restart('top')); // the first handshake is still in flight
    await pumpEventQueue();

    expect(t.execChannels.where((ch) => !ch.closed), hasLength(1));
    expect(c.status, ExecStatus.connected);
    final createPosts = t.posts.where((p) => p.path.endsWith('/exec')).toList();
    expect((createPosts.last.body as Map)['Cmd'], ['/bin/sh', '-c', 'top']);
    c.dispose();
  });

  test('ended is reported before the exit code arrives', () async {
    final t = execFake()..hangOn('GET', RegExp(r'/exec/[^/]+/json$'));
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    expect(c.status, ExecStatus.connected);
    var notifications = 0;
    c.addListener(() => notifications++);

    await t.lastChannel.controller.close(); // the process exits; the inspect never answers
    await pumpEventQueue();

    expect(c.status, ExecStatus.ended);
    expect(c.exitCode, isNull);
    expect(notifications, greaterThan(0)); // told about "ended" without waiting for the exit code
    c.dispose();
  });
}
