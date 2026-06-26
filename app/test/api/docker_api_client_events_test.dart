import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _FakeTransport implements Transport {
  String? lastStreamPath;
  final List<List<int>> chunks;
  _FakeTransport(this.chunks);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    lastStreamPath = path;
    return Stream.fromIterable(chunks);
  }
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{}', 200);
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async => http.Response('', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
  @override
  Future<void> close() async {}
}

void main() {
  test('streamEvents parses NDJSON across chunk boundaries', () async {
    final l1 = '{"Type":"container","Action":"start","Actor":{"Attributes":{"name":"a"}}}';
    final l2 = '{"Type":"image","Action":"pull","Actor":{"Attributes":{"name":"nginx"}}}';
    final all = '$l1\n$l2\n';
    final cut = l1.length - 4;
    final t = _FakeTransport([utf8.encode(all.substring(0, cut)), utf8.encode(all.substring(cut))]);
    final events = await DockerApiClient(t).streamEvents().toList();

    expect(t.lastStreamPath, '/events');
    expect(events.length, 2);
    expect(events[0].type, 'container');
    expect(events[1].target, 'nginx');
  });

  test('skips a malformed NDJSON line', () async {
    final t = _FakeTransport([utf8.encode('garbage\n{"Type":"volume","Action":"create"}\n')]);
    final events = await DockerApiClient(t).streamEvents().toList();
    expect(events.length, 1);
    expect(events.single.type, 'volume');
  });
}
