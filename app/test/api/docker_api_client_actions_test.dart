import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _Rec {
  final String verb; // 'post' | 'delete' | 'get'
  final String path;
  final Map<String, String>? query;
  _Rec(this.verb, this.path, this.query);
}

class _FakeTransport implements Transport {
  @override
  Future<void> close() async {}
  final List<_Rec> calls = [];
  int postStatus = 204;
  int deleteStatus = 204;
  http.Response getResponse = http.Response('{"Id":"a","Name":"/web"}', 200);

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
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) =>
      const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
}

void main() {
  test('inspectContainerDetail parses the rich model', () async {
    final t = _FakeTransport()..getResponse = http.Response('{"Id":"a","Name":"/web","Config":{"Image":"nginx"}}', 200);
    final c = await DockerApiClient(t).inspectContainerDetail('a');
    expect(c.image, 'nginx');
    expect(t.calls.single.path, '/containers/a/json');
  });

  test('start succeeds on 204 and on 304', () async {
    final t = _FakeTransport()..postStatus = 204;
    await DockerApiClient(t).startContainer('a');
    expect(t.calls.last.path, '/containers/a/start');

    t.postStatus = 304;
    await DockerApiClient(t).startContainer('a'); // must NOT throw
  });

  test('restart/pause/unpause/kill post to the right paths', () async {
    final t = _FakeTransport();
    final c = DockerApiClient(t);
    await c.restartContainer('a');
    await c.pauseContainer('a');
    await c.unpauseContainer('a');
    await c.killContainer('a');
    expect(t.calls.map((r) => r.path).toList(),
        ['/containers/a/restart', '/containers/a/pause', '/containers/a/unpause', '/containers/a/kill']);
  });

  test('rename posts the name query', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).renameContainer('a', 'newname');
    expect(t.calls.last.path, '/containers/a/rename');
    expect(t.calls.last.query, {'name': 'newname'});
  });

  test('remove deletes with force + v query', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).removeContainer('a', force: true, removeVolumes: true);
    expect(t.calls.last.verb, 'delete');
    expect(t.calls.last.path, '/containers/a');
    expect(t.calls.last.query, {'force': 'true', 'v': 'true'});
  });

  test('a 409 on remove throws DockerApiException', () async {
    final t = _FakeTransport()..deleteStatus = 409;
    expect(() => DockerApiClient(t).removeContainer('a'), throwsA(isA<DockerApiException>()));
  });

  test('a 500 on start throws DockerApiException', () async {
    final t = _FakeTransport()..postStatus = 500;
    expect(() => DockerApiClient(t).startContainer('a'), throwsA(isA<DockerApiException>()));
  });

  test('304 is rejected for non-start/stop actions (start/stop-only no-op)', () async {
    final t = _FakeTransport()..postStatus = 304;
    expect(() => DockerApiClient(t).restartContainer('a'), throwsA(isA<DockerApiException>()));
  });
}
