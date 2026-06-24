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
  Object? lastPostBody;
  http.Response getResponse = http.Response('{"Volumes":[]}', 200);
  int postStatus = 201;
  int deleteStatus = 204;

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    calls.add(_Rec('get', path, query));
    return getResponse;
  }
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    calls.add(_Rec('post', path, query));
    lastPostBody = body;
    return http.Response('{"Name":"data","Driver":"local"}', postStatus);
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
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  test('listVolumes parses the Volumes array', () async {
    final t = _FakeTransport()
      ..getResponse = http.Response('{"Volumes":[{"Name":"data","Driver":"local"}]}', 200);
    final vols = await DockerApiClient(t).listVolumes();
    expect(vols.single.name, 'data');
    expect(t.calls.single.path, '/volumes');
  });

  test('createVolume posts body, omitting empty Labels/DriverOpts, and returns the volume', () async {
    final t = _FakeTransport();
    final v = await DockerApiClient(t).createVolume(name: 'data', labels: const {'env': 'prod'});
    expect(v.name, 'data');
    expect(t.calls.last.path, '/volumes/create');
    final body = t.lastPostBody as Map<String, dynamic>;
    expect(body['Name'], 'data');
    expect(body['Driver'], 'local');
    expect(body['Labels'], {'env': 'prod'});
    expect(body.containsKey('DriverOpts'), isFalse);
  });

  test('removeVolume deletes with force', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).removeVolume('data', force: true);
    expect(t.calls.last.verb, 'delete');
    expect(t.calls.last.path, '/volumes/data');
    expect(t.calls.last.query, {'force': 'true'});
  });

  test('a 409 on remove throws DockerApiException', () async {
    final t = _FakeTransport()..deleteStatus = 409;
    expect(() => DockerApiClient(t).removeVolume('data'), throwsA(isA<DockerApiException>()));
  });

  test('pruneVolumes posts to /volumes/prune', () async {
    final t = _FakeTransport()..postStatus = 200;
    await DockerApiClient(t).pruneVolumes();
    expect(t.calls.last.path, '/volumes/prune');
  });
}
