import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _FakeTransport implements Transport {
  final http.Response getResponse;
  final List<List<int>> streamChunks;
  String? lastStreamPath;
  Map<String, String>? lastStreamQuery;
  _FakeTransport({required this.getResponse, this.streamChunks = const []});

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => getResponse;

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    lastStreamPath = path;
    lastStreamQuery = query;
    return Stream.fromIterable(streamChunks);
  }
}

List<int> frame(int type, List<int> payload) {
  final n = payload.length;
  return [type, 0, 0, 0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, ...payload];
}

void main() {
  test('inspectContainer parses tty', () async {
    final t = _FakeTransport(
      getResponse: http.Response('{"Id":"a","Name":"/w","Config":{"Image":"nginx","Tty":true},"State":{"Status":"running"}}', 200),
    );
    final c = await DockerApiClient(t).inspectContainer('a');
    expect(c.tty, isTrue);
    expect(c.name, 'w');
  });

  test('inspectContainer throws on non-200', () async {
    final t = _FakeTransport(getResponse: http.Response('no', 404));
    expect(() => DockerApiClient(t).inspectContainer('a'), throwsA(isA<DockerApiException>()));
  });

  test('streamContainerLogs demuxes non-TTY frames and builds query', () async {
    final t = _FakeTransport(
      getResponse: http.Response('{}', 200),
      streamChunks: [frame(1, utf8.encode('out')), frame(2, utf8.encode('err'))],
    );
    final chunks = await DockerApiClient(t)
        .streamContainerLogs('a', tty: false, follow: true, tail: 100, timestamps: true)
        .toList();

    expect(t.lastStreamPath, '/containers/a/logs');
    expect(t.lastStreamQuery, {
      'follow': 'true',
      'stdout': 'true',
      'stderr': 'true',
      'tail': '100',
      'timestamps': 'true',
    });
    expect(chunks.map((c) => c.source).toList(), [LogStream.stdout, LogStream.stderr]);
    expect(utf8.decode(chunks[0].bytes), 'out');
    expect(utf8.decode(chunks[1].bytes), 'err');
  });

  test('streamContainerLogs uses raw decoder for TTY and tail=all by default', () async {
    final t = _FakeTransport(
      getResponse: http.Response('{}', 200),
      streamChunks: [utf8.encode('hello')],
    );
    final chunks = await DockerApiClient(t).streamContainerLogs('a', tty: true).toList();

    expect(t.lastStreamQuery!['tail'], 'all');
    expect(chunks.single.source, LogStream.stdout);
    expect(utf8.decode(chunks.single.bytes), 'hello');
  });
}
