import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/image_detail.dart';

void main() {
  test('ImageDetail parses /images/{id}/json', () {
    final d = ImageDetail.fromJson({
      'Id': 'sha256:abc',
      'RepoTags': ['nginx:latest'],
      'Architecture': 'amd64',
      'Os': 'linux',
      'Size': 5000,
      'Created': '2026-01-02T03:04:05Z',
      'Config': {'Env': ['A=1'], 'ExposedPorts': {'80/tcp': {}, '443/tcp': {}}},
    });
    expect(d.architecture, 'amd64');
    expect(d.os, 'linux');
    expect(d.env, ['A=1']);
    expect(d.exposedPorts, containsAll(['80/tcp', '443/tcp']));
    expect(d.created, '2026-01-02T03:04:05Z');
  });

  test('ImageHistoryLayer parses a /history element', () {
    final l = ImageHistoryLayer.fromJson({
      'Id': 'sha256:def',
      'Created': 1700000000,
      'CreatedBy': '/bin/sh -c #(nop) CMD',
      'Size': 42,
      'Tags': ['nginx:latest'],
    });
    expect(l.id, 'sha256:def');
    expect(l.created, 1700000000);
    expect(l.createdBy, contains('CMD'));
    expect(l.size, 42);
    expect(l.tags, ['nginx:latest']);
  });

  test('ImageHistoryLayer tolerates null Tags', () {
    final l = ImageHistoryLayer.fromJson({'Id': 'x', 'Created': 0, 'CreatedBy': '', 'Size': 0});
    expect(l.tags, isEmpty);
  });
}
