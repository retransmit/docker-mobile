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

  test('listImages decodes the array (off main isolate)', () async {
    final t = _FakeTransport(http.Response(
      '[{"Id":"sha256:abc","RepoTags":["nginx:latest"],"Size":1234,"Created":99}]',
      200,
    ));
    final client = DockerApiClient(t);

    final images = await client.listImages();

    expect(t.lastPath, '/images/json');
    expect(images, hasLength(1));
    expect(images.first.id, 'sha256:abc');
    expect(images.first.repoTags, ['nginx:latest']);
    expect(images.first.size, 1234);
  });

  test('listImages decodes a large body on a background isolate', () async {
    // Build a >64KB array so the client takes the Isolate.run decode path.
    final entries = List.generate(
      2000,
      (i) => '{"Id":"sha256:img$i","RepoTags":["repo$i:latest"],"Size":$i,"Created":0}',
    );
    final t = _FakeTransport(http.Response('[${entries.join(',')}]', 200));
    final client = DockerApiClient(t);

    final images = await client.listImages();

    expect(images, hasLength(2000));
    expect(images.first.id, 'sha256:img0');
    expect(images.last.id, 'sha256:img1999');
    expect(images.last.size, 1999);
  });

  test('listImages throws DockerApiException on non-200', () async {
    final t = _FakeTransport(http.Response('boom', 500));
    final client = DockerApiClient(t);
    expect(
      () => client.listImages(),
      throwsA(isA<DockerApiException>().having((e) => e.statusCode, 'statusCode', 500)),
    );
  });

  test('getDiskUsage decodes the object (off main isolate)', () async {
    final t = _FakeTransport(http.Response(
      '{"Images":[{"Size":100}],"Containers":[{"SizeRw":20}],'
      '"Volumes":[{"UsageData":{"Size":5}}],"BuildCache":[{"Size":3}]}',
      200,
    ));
    final client = DockerApiClient(t);

    final df = await client.getDiskUsage();

    expect(t.lastPath, '/system/df');
    expect(df.images.size, 100);
    expect(df.containers.size, 20);
    expect(df.volumes.size, 5);
    expect(df.buildCache.size, 3);
    expect(df.total, 128);
  });

  test('getDiskUsage throws DockerApiException on non-200', () async {
    final t = _FakeTransport(http.Response('boom', 500));
    final client = DockerApiClient(t);
    expect(
      () => client.getDiskUsage(),
      throwsA(isA<DockerApiException>().having((e) => e.statusCode, 'statusCode', 500)),
    );
  });
}
