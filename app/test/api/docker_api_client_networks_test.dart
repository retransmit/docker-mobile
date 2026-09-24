import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/api/models/docker_network.dart';

import '../support/fake_transport.dart';

void main() {
  test('listNetworks parses the array', () async {
    final t = FakeTransport.always(
        http.Response('[{"Id":"n1","Name":"bridge","Driver":"bridge","Scope":"local"}]', 200));
    final nets = await DockerApiClient(t).listNetworks();
    expect(nets.single.name, 'bridge');
  });

  test('createNetwork builds the rich body and returns the Id', () async {
    final t = FakeTransport.always(http.Response('{"Id":"n9"}', 201));
    final id = await DockerApiClient(t).createNetwork(
      name: 'mynet',
      driver: 'bridge',
      internal: true,
      ipam: const [IpamConfig(subnet: '10.0.0.0/24', gateway: '10.0.0.1')],
      labels: const {'env': 'prod'},
    );

    expect(id, 'n9');
    expect(t.posts.last.path, '/networks/create');
    final body = t.posts.last.body as Map<String, dynamic>;
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
    final t = FakeTransport.always(http.Response('{"Id":"n9"}', 201));
    await DockerApiClient(t).createNetwork(name: 'n');
    final body = t.posts.last.body as Map<String, dynamic>;
    expect(body.containsKey('IPAM'), isFalse);
  });

  test('removeNetwork deletes (204) and a 403 throws', () async {
    final t = FakeTransport.always(http.Response('', 204));
    await DockerApiClient(t).removeNetwork('n1');
    expect(t.calls.where((c) => c.method == 'DELETE').map((c) => c.path), contains('/networks/n1'));

    final t2 = FakeTransport.always(http.Response('', 403));
    expect(() => DockerApiClient(t2).removeNetwork('bridge'), throwsA(isA<DockerApiException>()));
  });

  test('pruneNetworks posts to /networks/prune', () async {
    final t = FakeTransport.always(http.Response('{"Id":"n9"}', 200));
    await DockerApiClient(t).pruneNetworks();
    expect(t.posts.last.path, '/networks/prune');
  });
}
