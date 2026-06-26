import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _Rec {
  final String path;
  final Map<String, String>? query;
  _Rec(this.path, this.query);
}

class _FakeTransport implements Transport {
  @override
  Future<void> close() async {}
  final List<_Rec> posts = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path == '/info') return http.Response('{"ServerVersion":"27.0.3","NCPU":8,"Driver":"overlay2"}', 200);
    if (path == '/version') return http.Response('{"Version":"27.0.3","ApiVersion":"1.46"}', 200);
    if (path == '/system/df') return http.Response('{"Images":[{"Size":100}],"Containers":[],"Volumes":[],"BuildCache":[]}', 200);
    return http.Response('{}', 200);
  }
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(_Rec(path, query));
    return http.Response('', 200);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  test('getInfo/getVersion/getDiskUsage parse their endpoints', () async {
    final c = DockerApiClient(_FakeTransport());
    expect((await c.getInfo()).serverVersion, '27.0.3');
    expect((await c.getVersion()).apiVersion, '1.46');
    expect((await c.getDiskUsage()).images.size, 100);
  });

  test('pruneContainers/pruneBuildCache post to the right paths', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).pruneContainers();
    await DockerApiClient(t).pruneBuildCache();
    expect(t.posts.map((r) => r.path).toList(), ['/containers/prune', '/build/prune']);
  });

  test('systemPrune(all, volumes) runs the full sequence', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).systemPrune(allImages: true, includeVolumes: true);
    expect(t.posts.map((r) => r.path).toList(),
        ['/containers/prune', '/networks/prune', '/images/prune', '/build/prune', '/volumes/prune']);
    // images pruned with dangling:false (all)
    final imgCall = t.posts.firstWhere((r) => r.path == '/images/prune');
    expect(imgCall.query, {'filters': '{"dangling":["false"]}'});
  });

  test('systemPrune() defaults omit volumes and prune only dangling images', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).systemPrune();
    final paths = t.posts.map((r) => r.path).toList();
    expect(paths, ['/containers/prune', '/networks/prune', '/images/prune', '/build/prune']);
    expect(paths.contains('/volumes/prune'), isFalse);
    final imgCall = t.posts.firstWhere((r) => r.path == '/images/prune');
    expect(imgCall.query, {'filters': '{"dangling":["true"]}'});
  });
}
