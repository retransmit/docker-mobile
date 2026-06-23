import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container_detail.dart';

void main() {
  test('parses a full /containers/{id}/json', () {
    final c = ContainerDetail.fromJson({
      'Id': 'abc',
      'Name': '/web',
      'Created': '2026-01-02T03:04:05Z',
      'Config': {'Image': 'nginx', 'Cmd': ['nginx', '-g', 'daemon off;'], 'Env': ['A=1', 'B=2']},
      'State': {'Status': 'running', 'Running': true, 'Paused': false, 'ExitCode': 0, 'StartedAt': '2026-01-02T03:04:06Z'},
      'HostConfig': {'RestartPolicy': {'Name': 'unless-stopped'}},
      'Mounts': [
        {'Source': '/data', 'Destination': '/var/lib', 'Mode': 'rw', 'RW': true},
      ],
      'NetworkSettings': {
        'Networks': {'bridge': {}, 'frontend': {}},
        'Ports': {
          '80/tcp': [{'HostIp': '0.0.0.0', 'HostPort': '8080'}],
          '443/tcp': null,
        },
      },
    });

    expect(c.id, 'abc');
    expect(c.name, 'web');
    expect(c.image, 'nginx');
    expect(c.command, 'nginx -g daemon off;');
    expect(c.created, '2026-01-02T03:04:05Z');
    expect(c.state.status, 'running');
    expect(c.state.running, isTrue);
    expect(c.state.exitCode, 0);
    expect(c.env, ['A=1', 'B=2']);
    expect(c.restartPolicy, 'unless-stopped');
    expect(c.networks, containsAll(['bridge', 'frontend']));
    expect(c.mounts.single.source, '/data');
    expect(c.mounts.single.rw, isTrue);
    // 80/tcp bound to 8080; 443/tcp unbound.
    expect(c.ports.any((p) => p.privatePort == 80 && p.publicPort == 8080 && p.type == 'tcp'), isTrue);
    expect(c.ports.any((p) => p.privatePort == 443 && p.publicPort == null), isTrue);
  });

  test('tolerates missing nested objects', () {
    final c = ContainerDetail.fromJson({'Id': 'x', 'Name': 'y'});
    expect(c.image, '');
    expect(c.command, '');
    expect(c.state.status, '');
    expect(c.ports, isEmpty);
    expect(c.mounts, isEmpty);
    expect(c.env, isEmpty);
    expect(c.networks, isEmpty);
  });
}
