import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/exec_session_controller.dart';
import 'package:docker_mobile/src/transport/transport.dart';

import '../support/fake_transport.dart';

FakeTransport execFake({int exitCode = 0, bool failCreate = false}) => FakeTransport()
  ..onGet(RegExp(r'/exec/[^/]+/json$'), (_) => http.Response('{"Running":false,"ExitCode":$exitCode}', 200))
  ..onPost(RegExp(r'/exec$'), (_) => failCreate ? http.Response('boom', 500) : http.Response('{"Id":"e1"}', 201))
  ..onPost(RegExp(r'/resize$'), (_) => http.Response('', 200));

/// The [execFake] rules, with more for the test to control: while [attachGate]
/// or [inspectGate] is set, the attach or the exit-code inspect waits for it,
/// and with [failClose] the channels fail when they are closed.
class _ControlledExecFake extends FakeTransport {
  Completer<void>? attachGate;
  Completer<void>? inspectGate;
  bool failClose = false;

  _ControlledExecFake({int exitCode = 0}) {
    onGet(RegExp(r'/exec/[^/]+/json$'), (_) => http.Response('{"Running":false,"ExitCode":$exitCode}', 200));
    onPost(RegExp(r'/exec$'), (_) => http.Response('{"Id":"e1"}', 201));
    onPost(RegExp(r'/resize$'), (_) => http.Response('', 200));
  }

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async {
    await attachGate?.future;
    if (!failClose) return super.execAttach(execId, cols: cols, rows: rows);
    final ch = _FailingCloseChannel();
    execChannels.add(ch);
    return ch;
  }

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path.endsWith('/json')) await inspectGate?.future;
    return super.get(path, query: query);
  }
}

/// A channel whose close fails once it has closed, as a connection that is already gone does.
class _FailingCloseChannel extends FakeExecChannel {
  @override
  Future<void> close() async {
    await super.close();
    throw const DockerError(DockerErrorKind.network, 'connection closed');
  }
}

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

  test('an ended session sends no resize', () async {
    int resizes(FakeTransport t) => t.posts.where((p) => p.path.endsWith('/resize')).length;

    // Ended from outside.
    final t = execFake();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    c.terminal.onResize?.call(90, 20, 0, 0);
    expect(resizes(t), 1); // a live session does send it
    await c.end();
    c.terminal.onResize?.call(100, 30, 0, 0);
    await pumpEventQueue();
    expect(resizes(t), 1);
    c.dispose();

    // Ended because the output closed by itself.
    final t2 = execFake();
    final c2 = ExecSessionController(DockerApiClient(t2), 'cid');
    await pumpEventQueue();
    await t2.lastChannel.controller.close();
    await pumpEventQueue();
    expect(c2.status, ExecStatus.ended);
    c2.terminal.onResize?.call(100, 30, 0, 0);
    await pumpEventQueue();
    expect(resizes(t2), 0);
    c2.dispose();
  });

  test('a failed resize is not an unhandled error', () async {
    final t = execFake()
      ..throwOn('POST', RegExp(r'/resize$'), const DockerError(DockerErrorKind.network, 'connection closed'));
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    expect(c.status, ExecStatus.connected);

    c.terminal.onResize?.call(100, 30, 0, 0);
    await pumpEventQueue(); // an error nobody handles would fail the test here

    expect(t.posts.where((p) => p.path.endsWith('/resize')), hasLength(1)); // it was sent, and it failed
    expect(c.status, ExecStatus.connected);
    c.dispose();
  });

  test('end() while the attach is pending closes the late channel and stays ended', () async {
    final t = _ControlledExecFake()..attachGate = Completer<void>();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue(); // the exec is created, the attach is waiting
    expect(c.status, ExecStatus.connecting);

    unawaited(c.end());
    var notifications = 0;
    c.addListener(() => notifications++);
    t.attachGate!.complete();
    await pumpEventQueue();

    expect(t.execChannels.single.closed, isTrue);
    expect(c.status, ExecStatus.ended);
    expect(notifications, 0);
    c.dispose();
  });

  test('dispose() while the attach is pending closes the late channel', () async {
    final t = _ControlledExecFake()..attachGate = Completer<void>();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue(); // the exec is created, the attach is waiting
    c.dispose();
    t.attachGate!.complete();
    await pumpEventQueue(); // a notification after dispose would throw and fail the test

    expect(t.execChannels.single.closed, isTrue);
  });

  test('a late exit code of the previous exec does not land on a restarted session', () async {
    final t = _ControlledExecFake(exitCode: 7);
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    t.inspectGate = Completer<void>();

    await t.lastChannel.controller.close(); // the output closes; the exit-code inspect is held open
    await pumpEventQueue();
    expect(c.status, ExecStatus.ended);
    expect(c.exitCode, isNull);

    await c.restart('x');
    await pumpEventQueue();
    expect(c.status, ExecStatus.connected);

    t.inspectGate!.complete(); // the previous exec's inspect answers now, with exit code 7
    await pumpEventQueue();
    expect(c.exitCode, isNull);
    expect(c.status, ExecStatus.connected);
    c.dispose();
  });

  test('end() notifies once; the channel it closes is not reported as a second ending', () async {
    final t = execFake();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    var notifications = 0;
    c.addListener(() => notifications++);

    await c.end();
    await pumpEventQueue();

    expect(notifications, 1);
    c.dispose();
  });

  test('a restart never reports the old session as ended', () async {
    final t = execFake();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    final seen = <ExecStatus>[];
    c.addListener(() => seen.add(c.status));

    await c.restart('top');
    await pumpEventQueue();

    expect(seen, [ExecStatus.connecting, ExecStatus.connected]);
    c.dispose();
  });

  test('restart() after dispose does nothing', () async {
    final t = execFake();
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    c.dispose();

    await c.restart('top'); // starting again would notify after dispose and throw
    await pumpEventQueue();

    expect(t.posts.where((p) => p.path.endsWith('/exec')), hasLength(1));
  });

  test('a channel that fails to close does not stop a restart or an end()', () async {
    final t = _ControlledExecFake()..failClose = true;
    final c = ExecSessionController(DockerApiClient(t), 'cid');
    await pumpEventQueue();
    expect(c.status, ExecStatus.connected);

    await c.restart('top');
    await pumpEventQueue(); // the old channel's close error must not surface as unhandled
    expect(t.execChannels.first.closed, isTrue);
    expect(c.status, ExecStatus.connected);

    await c.end(); // completes although the close throws
    expect(t.execChannels.last.closed, isTrue);
    expect(c.status, ExecStatus.ended);
    c.dispose();
  });
}
