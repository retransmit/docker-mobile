import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/logs_notifier.dart';

/// Returns a fresh single-subscription stream of [chunks] on every call,
/// so re-subscribing (follow/tail/timestamps changes) works.
class _FakeTransport implements Transport {
  final List<List<int>> chunks;
  _FakeTransport(this.chunks);
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{}', 200);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => Stream.fromIterable(chunks);
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) =>
      throw UnimplementedError();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
}

/// Streams whatever is pushed into [controller], so tests can drive bytes,
/// errors, and pause/cancel timing explicitly.
class _ControllerTransport implements Transport {
  final StreamController<List<int>> controller;
  _ControllerTransport(this.controller);
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{}', 200);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => controller.stream;
  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) =>
      throw UnimplementedError();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
}

List<int> frame(int type, List<int> payload) {
  final n = payload.length;
  return [type, 0, 0, 0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, ...payload];
}

void main() {
  test('assembles lines across chunk boundaries', () async {
    final client = DockerApiClient(_FakeTransport([
      frame(1, utf8.encode('hel')),
      frame(1, utf8.encode('lo\nwor')),
      frame(1, utf8.encode('ld\n')),
    ]));
    final n = LogsNotifier(client, 'a', false);
    await pumpEventQueue();
    expect(n.state.lines.map((l) => l.text).toList(), ['hello', 'world']);
    n.dispose();
  });

  test('tags stderr lines', () async {
    final client = DockerApiClient(_FakeTransport([frame(2, utf8.encode('boom\n'))]));
    final n = LogsNotifier(client, 'a', false);
    await pumpEventQueue();
    expect(n.state.lines.single.source, LogStream.stderr);
    n.dispose();
  });

  test('search filters visible lines', () async {
    final client = DockerApiClient(_FakeTransport([frame(1, utf8.encode('apple\nbanana\n'))]));
    final n = LogsNotifier(client, 'a', false);
    await pumpEventQueue();
    n.setSearch('ban');
    expect(n.state.visibleLines.map((l) => l.text).toList(), ['banana']);
    n.dispose();
  });

  test('caps the buffer at kLogBufferCap lines', () async {
    final many = '${List.generate(kLogBufferCap + 10, (i) => 'line$i').join('\n')}\n';
    final client = DockerApiClient(_FakeTransport([frame(1, utf8.encode(many))]));
    final n = LogsNotifier(client, 'a', false);
    await pumpEventQueue();
    expect(n.state.lines.length, kLogBufferCap);
    expect(n.state.lines.last.text, 'line${kLogBufferCap + 9}'); // newest kept
    n.dispose();
  });

  test('reaches idle status when a non-following stream completes', () async {
    final client = DockerApiClient(_FakeTransport([frame(1, utf8.encode('x\n'))]));
    final n = LogsNotifier(client, 'a', false);
    await pumpEventQueue();
    expect(n.state.status, LogsStatus.idle);
    n.dispose();
  });

  test('pause stops the live stream and preserves buffered lines', () async {
    final controller = StreamController<List<int>>();
    final client = DockerApiClient(_ControllerTransport(controller));
    final n = LogsNotifier(client, 'a', false);

    controller.add(frame(1, utf8.encode('one\n')));
    await pumpEventQueue();
    expect(n.state.lines.map((l) => l.text).toList(), ['one']);

    n.setFollowing(false);
    await pumpEventQueue();
    expect(n.state.status, LogsStatus.paused);
    expect(n.state.lines.map((l) => l.text).toList(), ['one']); // NOT cleared

    // Bytes after pause must not appear (subscription was canceled).
    controller.add(frame(1, utf8.encode('two\n')));
    await pumpEventQueue();
    expect(n.state.lines.map((l) => l.text).toList(), ['one']);

    n.dispose();
    await controller.close();
  });

  test('enters error status and preserves lines on stream error', () async {
    final controller = StreamController<List<int>>();
    final client = DockerApiClient(_ControllerTransport(controller));
    final n = LogsNotifier(client, 'a', false);

    controller.add(frame(1, utf8.encode('before\n')));
    await pumpEventQueue();
    controller.addError(Exception('boom'));
    await pumpEventQueue();

    expect(n.state.status, LogsStatus.error);
    expect(n.state.error, contains('boom'));
    expect(n.state.lines.map((l) => l.text).toList(), ['before']); // preserved

    n.dispose();
    await controller.close();
  });

  test('parses the leading RFC3339 timestamp when timestamps enabled', () async {
    final line = '2026-01-02T03:04:05.000000000Z hello\n';
    final client = DockerApiClient(_FakeTransport([frame(1, utf8.encode(line))]));
    final n = LogsNotifier(client, 'a', false);
    n.setTimestamps(true); // re-subscribes with timestamps on
    await pumpEventQueue();

    final l = n.state.lines.single;
    expect(l.text, 'hello');
    expect(l.timestamp, isNotNull);
    expect(l.timestamp!.toUtc(), DateTime.utc(2026, 1, 2, 3, 4, 5));
    n.dispose();
  });
}
