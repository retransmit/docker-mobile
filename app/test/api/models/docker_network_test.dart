import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_network.dart';

void main() {
  test('DockerNetwork parses a /networks element', () {
    final n = DockerNetwork.fromJson({'Id': 'n1', 'Name': 'bridge', 'Driver': 'bridge', 'Scope': 'local'});
    expect(n.id, 'n1');
    expect(n.name, 'bridge');
    expect(n.driver, 'bridge');
    expect(n.scope, 'local');
  });

  test('NetworkDetail parses IPAM, containers, labels', () {
    final d = NetworkDetail.fromJson({
      'Id': 'n1',
      'Name': 'mynet',
      'Driver': 'bridge',
      'Scope': 'local',
      'Internal': true,
      'Attachable': false,
      'EnableIPv6': false,
      'IPAM': {
        'Driver': 'default',
        'Config': [{'Subnet': '10.0.0.0/24', 'Gateway': '10.0.0.1'}],
      },
      'Containers': {
        'abc123': {'Name': 'web', 'IPv4Address': '10.0.0.2/24'},
      },
      'Labels': {'env': 'prod'},
      'Options': {'com.docker.network.bridge.name': 'br0'},
    });
    expect(d.name, 'mynet');
    expect(d.internal, isTrue);
    expect(d.ipamDriver, 'default');
    expect(d.ipam.single.subnet, '10.0.0.0/24');
    expect(d.ipam.single.gateway, '10.0.0.1');
    expect(d.containers.single.name, 'web');
    expect(d.containers.single.ipv4, '10.0.0.2/24');
    expect(d.labels, {'env': 'prod'});
    expect(d.options['com.docker.network.bridge.name'], 'br0');
  });

  test('NetworkDetail tolerates missing nested fields', () {
    final d = NetworkDetail.fromJson({'Id': 'x', 'Name': 'y'});
    expect(d.ipam, isEmpty);
    expect(d.containers, isEmpty);
    expect(d.labels, isEmpty);
    expect(d.internal, isFalse);
  });
}
