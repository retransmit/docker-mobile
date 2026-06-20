import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container_inspect.dart';

void main() {
  test('parses /containers/{id}/json', () {
    final c = ContainerInspect.fromJson({
      'Id': 'abc',
      'Name': '/web',
      'Config': {'Image': 'nginx', 'Tty': true},
      'State': {'Status': 'running'},
    });
    expect(c.id, 'abc');
    expect(c.name, 'web'); // leading slash stripped
    expect(c.image, 'nginx');
    expect(c.state, 'running');
    expect(c.tty, isTrue);
  });

  test('defaults tty to false and tolerates missing nested fields', () {
    final c = ContainerInspect.fromJson({'Id': 'x', 'Name': 'y'});
    expect(c.tty, isFalse);
    expect(c.image, '');
    expect(c.state, '');
  });
}
