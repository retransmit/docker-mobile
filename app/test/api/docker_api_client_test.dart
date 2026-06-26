import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _FakeTransport implements Transport {
  @override
  Future<void> close() async {}
  final http.Response response;
  String? lastPath;
  Map<String, String>? lastQuery;
  _FakeTransport(this.response);

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    lastPath = path;
    lastQuery = query;
    return response;
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) =>
      throw UnimplementedError();

  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) =>
      throw UnimplementedError();

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      throw UnimplementedError();

  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) =>
      const Stream.empty();
}

void main() {
  test('listContainers decodes the array', () async {
    final t = _FakeTransport(http.Response(
      '[{"Id":"a","Names":["/web"],"Image":"nginx","State":"running","Status":"Up"}]',
      200,
    ));
    final client = DockerApiClient(t);

    final containers = await client.listContainers();

    expect(t.lastPath, '/containers/json');
    expect(t.lastQuery, {'all': 'true'});
    expect(containers, hasLength(1));
    expect(containers.first.id, 'a');
    expect(containers.first.image, 'nginx');
  });

  test('listContainers throws DockerApiException on non-200', () async {
    final t = _FakeTransport(http.Response('boom', 500));
    final client = DockerApiClient(t);
    expect(
      () => client.listContainers(),
      throwsA(isA<DockerApiException>().having((e) => e.statusCode, 'statusCode', 500)),
    );
  });
}
