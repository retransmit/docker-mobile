import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_container.dart';

void main() {
  test('parses a /containers/json element', () {
    final json = {
      'Id': 'abc123',
      'Names': ['/web'],
      'Image': 'nginx:latest',
      'State': 'running',
      'Status': 'Up 2 hours',
    };
    final c = DockerContainer.fromJson(json);
    expect(c.id, 'abc123');
    expect(c.names, ['/web']);
    expect(c.image, 'nginx:latest');
    expect(c.state, 'running');
    expect(c.status, 'Up 2 hours');
  });

  test('defaults all optional fields when absent', () {
    // Only Id present — exercises the ?? [] / ?? '' fallbacks.
    final c = DockerContainer.fromJson({'Id': 'x'});
    expect(c.names, isEmpty);
    expect(c.image, '');
    expect(c.state, '');
    expect(c.status, '');
  });

  test('throws when the required Id is missing', () {
    expect(
      () => DockerContainer.fromJson({'Image': 'busybox'}),
      throwsA(isA<TypeError>()),
    );
  });
}
