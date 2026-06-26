import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_event.dart';

void main() {
  test('parses type/action/target(name) and time from timeNano', () {
    final e = DockerEvent.fromJson({
      'Type': 'container',
      'Action': 'start',
      'Actor': {'ID': 'abcdef0123456789', 'Attributes': {'name': 'web', 'image': 'nginx'}},
      'timeNano': 1700000000000000000,
    });
    expect(e.type, 'container');
    expect(e.action, 'start');
    expect(e.target, 'web');
    expect(e.time, isNotNull);
    expect(e.time!.microsecondsSinceEpoch, 1700000000000000000 ~/ 1000);
  });

  test('falls back to short ID when no name; tolerates missing Actor', () {
    final e = DockerEvent.fromJson({
      'Type': 'image',
      'Action': 'pull',
      'Actor': {'ID': 'sha256abcdef0123456789'},
    });
    expect(e.target, 'sha256abcdef'); // first 12 chars
    final e2 = DockerEvent.fromJson({'Type': 'network', 'Action': 'connect'});
    expect(e2.target, '');
    expect(e2.time, isNull);
  });
}
