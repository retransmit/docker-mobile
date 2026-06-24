import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_image.dart';

void main() {
  test('parses /images/json element', () {
    final i = DockerImage.fromJson({
      'Id': 'sha256:abc',
      'RepoTags': ['nginx:latest', 'nginx:1.27'],
      'Size': 1234,
      'Created': 1700000000,
    });
    expect(i.id, 'sha256:abc');
    expect(i.repoTags, ['nginx:latest', 'nginx:1.27']);
    expect(i.size, 1234);
    expect(i.created, 1700000000);
  });

  test('tolerates null RepoTags', () {
    final i = DockerImage.fromJson({'Id': 'x', 'Size': 0, 'Created': 0});
    expect(i.repoTags, isEmpty);
  });
}
