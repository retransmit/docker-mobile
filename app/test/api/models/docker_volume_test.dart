import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_volume.dart';

void main() {
  test('parses a volume', () {
    final v = DockerVolume.fromJson({
      'Name': 'data',
      'Driver': 'local',
      'Mountpoint': '/var/lib/docker/volumes/data/_data',
      'CreatedAt': '2026-01-02T03:04:05Z',
      'Scope': 'local',
      'Labels': {'env': 'prod'},
      'Options': {'type': 'nfs'},
    });
    expect(v.name, 'data');
    expect(v.driver, 'local');
    expect(v.mountpoint, '/var/lib/docker/volumes/data/_data');
    expect(v.createdAt, '2026-01-02T03:04:05Z');
    expect(v.scope, 'local');
    expect(v.labels, {'env': 'prod'});
    expect(v.options, {'type': 'nfs'});
  });

  test('tolerates missing/null fields', () {
    final v = DockerVolume.fromJson({'Name': 'x', 'Labels': null, 'Options': null});
    expect(v.driver, '');
    expect(v.mountpoint, '');
    expect(v.labels, isEmpty);
    expect(v.options, isEmpty);
  });
}
