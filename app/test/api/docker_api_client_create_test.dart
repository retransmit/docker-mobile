import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/api/models/container_create_config.dart';

import '../support/fake_transport.dart';

void main() {
  test('createContainer posts the config and returns the Id', () async {
    final t = FakeTransport()
      ..onPost('/containers/create', (_) => http.Response('{"Id":"abc123"}', 201));
    final id = await DockerApiClient(t).createContainer(
        const ContainerCreateConfig(image: 'nginx'), name: 'web');
    expect(id, 'abc123');
    final rec = t.posts.single;
    expect(rec.path, '/containers/create');
    expect(rec.query, {'name': 'web'});
    expect((rec.body as Map)['Image'], 'nginx');
  });

  test('no name query when name is null/empty; non-201 throws', () async {
    final t = FakeTransport()
      ..onPost('/containers/create', (_) => http.Response('{"Id":"abc123"}', 201));
    await DockerApiClient(t).createContainer(const ContainerCreateConfig(image: 'nginx'));
    expect(t.posts.single.query, isNull);

    final t2 = FakeTransport()
      ..onPost('/containers/create', (_) => http.Response('{"message":"No such image: nginx"}', 404));
    expect(
      () => DockerApiClient(t2).createContainer(const ContainerCreateConfig(image: 'nginx')),
      throwsA(isA<DockerApiException>()),
    );
  });
}
