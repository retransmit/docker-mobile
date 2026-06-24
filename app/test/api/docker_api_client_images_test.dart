import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _Rec {
  final String verb, path;
  final Map<String, String>? query;
  _Rec(this.verb, this.path, this.query);
}

class _FakeTransport implements Transport {
  final List<_Rec> calls = [];
  http.Response getResponse = http.Response('[]', 200);
  int postStatus = 200;
  int deleteStatus = 200;
  List<List<int>> pullChunks = const [];

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    calls.add(_Rec('get', path, query));
    return getResponse;
  }
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    calls.add(_Rec('post', path, query));
    return http.Response('', postStatus);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    calls.add(_Rec('delete', path, query));
    return http.Response('', deleteStatus);
  }
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) {
    calls.add(_Rec('postStream', path, query));
    return Stream.fromIterable(pullChunks);
  }
}

void main() {
  test('listImages parses the array', () async {
    final t = _FakeTransport()
      ..getResponse = http.Response('[{"Id":"a","RepoTags":["nginx:latest"],"Size":1,"Created":2}]', 200);
    final images = await DockerApiClient(t).listImages();
    expect(images.single.repoTags, ['nginx:latest']);
    expect(t.calls.single.path, '/images/json');
  });

  test('pullImage parses newline-delimited progress and queries fromImage+tag', () async {
    final t = _FakeTransport()
      ..pullChunks = [
        utf8.encode('{"status":"Pulling fs layer","id":"l1"}\n{"status":"Down'),
        utf8.encode('loading","id":"l1","progressDetail":{"current":5,"total":10}}\n'),
        utf8.encode('{"error":"nope"}\n'),
      ];
    final events = await DockerApiClient(t).pullImage('nginx', tag: '1.27').toList();

    expect(t.calls.last.path, '/images/create');
    expect(t.calls.last.query, {'fromImage': 'nginx', 'tag': '1.27'});
    expect(events.map((e) => e.status).toList(), ['Pulling fs layer', 'Downloading', '']);
    expect(events[1].current, 5);
    expect(events.last.error, 'nope');
  });

  test('tagImage posts repo+tag (201)', () async {
    final t = _FakeTransport()..postStatus = 201;
    await DockerApiClient(t).tagImage('a', repo: 'myrepo', tag: 'v1');
    expect(t.calls.last.path, '/images/a/tag');
    expect(t.calls.last.query, {'repo': 'myrepo', 'tag': 'v1'});
  });

  test('removeImage deletes with force+noprune', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).removeImage('a', force: true, noprune: true);
    expect(t.calls.last.verb, 'delete');
    expect(t.calls.last.path, '/images/a');
    expect(t.calls.last.query, {'force': 'true', 'noprune': 'true'});
  });

  test('pruneImages sends dangling filter', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).pruneImages(danglingOnly: false);
    expect(t.calls.last.path, '/images/prune');
    expect(t.calls.last.query, {'filters': '{"dangling":["false"]}'});
  });

  test('tagImage throws on non-201', () async {
    final t = _FakeTransport()..postStatus = 409;
    expect(() => DockerApiClient(t).tagImage('a', repo: 'r'), throwsA(isA<DockerApiException>()));
  });
}
