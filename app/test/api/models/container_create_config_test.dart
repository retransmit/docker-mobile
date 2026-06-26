import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container_create_config.dart';

void main() {
  test('image-only config has no HostConfig and no extras', () {
    final json = const ContainerCreateConfig(image: 'nginx').toJson();
    expect(json, {'Image': 'nginx'});
  });

  test('parseCommand splits on whitespace; empty -> []', () {
    expect(ContainerCreateConfig.parseCommand('nginx -g daemon off'), ['nginx', '-g', 'daemon', 'off']);
    expect(ContainerCreateConfig.parseCommand('   '), <String>[]);
  });

  test('rich config builds the expected Docker shapes', () {
    final json = const ContainerCreateConfig(
      image: 'nginx:latest',
      cmd: ['echo', 'hi'],
      env: {'K': 'V'},
      ports: [PortMapping(containerPort: '80', protocol: 'tcp', hostPort: '8080')],
      binds: {'/data': '/var/www'},
      restartPolicy: 'unless-stopped',
      labels: {'app': 'web'},
      network: 'frontend',
      memoryBytes: 536870912,
      cpus: 1.5,
    ).toJson();

    expect(json['Image'], 'nginx:latest');
    expect(json['Cmd'], ['echo', 'hi']);
    expect(json['Env'], ['K=V']);
    expect(json['Labels'], {'app': 'web'});
    expect(json['ExposedPorts'], {'80/tcp': {}});
    final hc = json['HostConfig'] as Map<String, dynamic>;
    expect(hc['PortBindings'], {'80/tcp': [{'HostPort': '8080'}]});
    expect(hc['Binds'], ['/data:/var/www']);
    expect(hc['RestartPolicy'], {'Name': 'unless-stopped'});
    expect(hc['NetworkMode'], 'frontend');
    expect(hc['Memory'], 536870912);
    expect(hc['NanoCpus'], 1500000000);
  });
}
