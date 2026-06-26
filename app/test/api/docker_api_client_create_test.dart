import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/api/models/container_create_config.dart';

class _Rec {
  final String path;
  final Map<String, String>? query;
  final Object? body;
  _Rec(this.path, this.query, this.body);
}

class _FakeTransport implements Transport {
  final List<_Rec> posts = [];
  int createStatus = 201;
  String createBody = '{"Id":"abc123"}';
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(_Rec(path, query, body));
    if (path == '/containers/create') return http.Response(createBody, createStatus);
    return http.Response('', 204);
  }
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  test('createContainer posts the config and returns the Id', () async {
    final t = _FakeTransport();
    final id = await DockerApiClient(t).createContainer(
        const ContainerCreateConfig(image: 'nginx'), name: 'web');
    expect(id, 'abc123');
    final rec = t.posts.single;
    expect(rec.path, '/containers/create');
    expect(rec.query, {'name': 'web'});
    expect((rec.body as Map)['Image'], 'nginx');
  });

  test('no name query when name is null/empty; non-201 throws', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).createContainer(const ContainerCreateConfig(image: 'nginx'));
    expect(t.posts.single.query, isNull);

    final t2 = _FakeTransport()..createStatus = 404..createBody = '{"message":"No such image: nginx"}';
    expect(
      () => DockerApiClient(t2).createContainer(const ContainerCreateConfig(image: 'nginx')),
      throwsA(isA<DockerApiException>()),
    );
  });
}
