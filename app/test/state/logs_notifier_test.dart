import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/logs_notifier.dart';

class _FakeTransport implements Transport {
  final List<List<int>> chunks;
  _FakeTransport(this.chunks);
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{}', 200);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => Stream.fromIterable(chunks);
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
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.lines.map((l) => l.text).toList(), ['hello', 'world']);
    n.dispose();
  });

  test('tags stderr lines', () async {
    final client = DockerApiClient(_FakeTransport([frame(2, utf8.encode('boom\n'))]));
    final n = LogsNotifier(client, 'a', false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.lines.single.source, LogStream.stderr);
    n.dispose();
  });

  test('search filters visible lines', () async {
    final client = DockerApiClient(_FakeTransport([frame(1, utf8.encode('apple\nbanana\n'))]));
    final n = LogsNotifier(client, 'a', false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    n.setSearch('ban');
    expect(n.state.visibleLines.map((l) => l.text).toList(), ['banana']);
    n.dispose();
  });

  test('caps the buffer at kLogBufferCap lines', () async {
    final many = '${List.generate(kLogBufferCap + 10, (i) => 'line$i').join('\n')}\n';
    final client = DockerApiClient(_FakeTransport([frame(1, utf8.encode(many))]));
    final n = LogsNotifier(client, 'a', false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.lines.length, kLogBufferCap);
    expect(n.state.lines.last.text, 'line${kLogBufferCap + 9}'); // newest kept
    n.dispose();
  });

  test('reaches idle status when a non-following stream completes', () async {
    final client = DockerApiClient(_FakeTransport([frame(1, utf8.encode('x\n'))]));
    final n = LogsNotifier(client, 'a', false);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(n.state.status, LogsStatus.idle);
    n.dispose();
  });
}
