import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/api/models/docker_network.dart';

class _FakeTransport implements Transport {
  @override
  Future<void> close() async {}
  Object? lastPostBody;
  String? lastPostPath;
  final List<String> deletes = [];
  http.Response getResponse = http.Response('[]', 200);
  int postStatus = 201;
  int deleteStatus = 204;

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => getResponse;
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    lastPostPath = path;
    lastPostBody = body;
    return http.Response('{"Id":"n9"}', postStatus);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    deletes.add(path);
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
  test('listNetworks parses the array', () async {
    final t = _FakeTransport()
      ..getResponse = http.Response('[{"Id":"n1","Name":"bridge","Driver":"bridge","Scope":"local"}]', 200);
    final nets = await DockerApiClient(t).listNetworks();
    expect(nets.single.name, 'bridge');
  });

  test('createNetwork builds the rich body and returns the Id', () async {
    final t = _FakeTransport();
    final id = await DockerApiClient(t).createNetwork(
      name: 'mynet',
      driver: 'bridge',
      internal: true,
      ipam: const [IpamConfig(subnet: '10.0.0.0/24', gateway: '10.0.0.1')],
      labels: const {'env': 'prod'},
    );

    expect(id, 'n9');
    expect(t.lastPostPath, '/networks/create');
    final body = t.lastPostBody as Map<String, dynamic>;
    expect(body['Name'], 'mynet');
    expect(body['Driver'], 'bridge');
    expect(body['Internal'], true);
    expect(body['IPAM']['Config'], [
      {'Subnet': '10.0.0.0/24', 'Gateway': '10.0.0.1'}
    ]);
    expect(body['Labels'], {'env': 'prod'});
    expect(body.containsKey('Options'), isFalse); // empty options omitted
  });

  test('createNetwork omits IPAM when there are no configs', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).createNetwork(name: 'n');
    final body = t.lastPostBody as Map<String, dynamic>;
    expect(body.containsKey('IPAM'), isFalse);
  });

  test('removeNetwork deletes (204) and a 403 throws', () async {
    final t = _FakeTransport();
    await DockerApiClient(t).removeNetwork('n1');
    expect(t.deletes, contains('/networks/n1'));

    final t2 = _FakeTransport()..deleteStatus = 403;
    expect(() => DockerApiClient(t2).removeNetwork('bridge'), throwsA(isA<DockerApiException>()));
  });

  test('pruneNetworks posts to /networks/prune', () async {
    final t = _FakeTransport()..postStatus = 200;
    await DockerApiClient(t).pruneNetworks();
    expect(t.lastPostPath, '/networks/prune');
  });
}
