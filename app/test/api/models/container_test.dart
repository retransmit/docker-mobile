import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container.dart';

void main() {
  test('parses a /containers/json element', () {
    final json = {
      'Id': 'abc123',
      'Names': ['/web'],
      'Image': 'nginx:latest',
      'State': 'running',
      'Status': 'Up 2 hours',
    };
    final c = Container.fromJson(json);
    expect(c.id, 'abc123');
    expect(c.names, ['/web']);
    expect(c.image, 'nginx:latest');
    expect(c.state, 'running');
    expect(c.status, 'Up 2 hours');
  });

  test('tolerates missing optional fields', () {
    final c = Container.fromJson({'Id': 'x', 'Names': <String>[], 'Image': 'busybox'});
    expect(c.state, '');
    expect(c.status, '');
  });
}
