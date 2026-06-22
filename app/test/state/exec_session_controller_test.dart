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
  Future<void> close() {
    closed = true;
    return controller.close();
  }
}

/// Transport whose execAttach only completes when [gate] is fired, letting a
/// test dispose the controller while the handshake is still in flight.
class _GatedExecTransport implements Transport {
  final _FakeExecChannel channel;
  final Completer<void> gate;
  _GatedExecTransport({required this.channel, required this.gate});

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
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async {
    await gate.future;
    return channel;
  }
}

class _ExecFakeTransport implements Transport {
  final _FakeExecChannel channel;
  final String execId;
  final int exitCode;
  _ExecFakeTransport({required this.channel, required this.execId, this.exitCode = 0});

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async =>
      http.Response('{"Running":false,"ExitCode":$exitCode}', 200);
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) async =>
      http.Response('{"Id":"$execId"}', 201);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async => channel;
}

void main() {
  test('forwards terminal input to the channel', () async {
    final ch = _FakeExecChannel();
    final client = DockerApiClient(_ExecFakeTransport(channel: ch, execId: 'e1'));
    final c = ExecSessionController(client, 'cid');
    await pumpEventQueue();
    expect(c.status, ExecStatus.connected);

    c.terminal.onOutput?.call('hi');
    expect(ch.sent.map(utf8.decode).toList(), ['hi']);
    c.dispose();
  });

  test('status becomes ended with the exit code when output closes', () async {
    final ch = _FakeExecChannel();
    final client = DockerApiClient(_ExecFakeTransport(channel: ch, execId: 'e1', exitCode: 137));
    final c = ExecSessionController(client, 'cid');
    await pumpEventQueue();

    await ch.controller.close();
    await pumpEventQueue();

    expect(c.status, ExecStatus.ended);
    expect(c.exitCode, 137);
    c.dispose();
  });

  test('disposing while the attach handshake is in flight closes the channel and does not notify', () async {
    final ch = _FakeExecChannel();
    final gate = Completer<void>();
    final client = DockerApiClient(_GatedExecTransport(channel: ch, gate: gate));
    final c = ExecSessionController(client, 'cid');
    var notifyCount = 0;
    c.addListener(() => notifyCount++);
    await pumpEventQueue();
    expect(c.status, ExecStatus.connecting);

    c.dispose();
    final notifiesBeforeResolve = notifyCount;

    // Let the in-flight attach resolve now that we're disposed. A post-dispose
    // notifyListeners() would throw (FlutterError) on a disposed ChangeNotifier.
    gate.complete();
    await pumpEventQueue();

    expect(ch.closed, isTrue, reason: 'resolved channel must be torn down, not leaked');
    expect(notifyCount, notifiesBeforeResolve,
        reason: 'must not notify listeners after dispose');
  });
}
