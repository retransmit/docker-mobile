import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_api_client.dart';

import '../support/fake_transport.dart';

void main() {
  test('inspectContainerDetail parses the rich model', () async {
    final t = FakeTransport.always(http.Response('{"Id":"a","Name":"/web","Config":{"Image":"nginx"}}', 200));
    final c = await DockerApiClient(t).inspectContainerDetail('a');
    expect(c.image, 'nginx');
    expect(t.calls.single.path, '/containers/a/json');
  });

  test('start succeeds on 204 and on 304', () async {
    final t = FakeTransport.always(http.Response('', 204));
    await DockerApiClient(t).startContainer('a');
    expect(t.calls.last.path, '/containers/a/start');

    t.onPost(RegExp('.*'), (_) => http.Response('', 304));
    await DockerApiClient(t).startContainer('a'); // must NOT throw
  });

  test('restart/pause/unpause/kill post to the right paths', () async {
    final t = FakeTransport.always(http.Response('', 204));
    final c = DockerApiClient(t);
    await c.restartContainer('a');
    await c.pauseContainer('a');
    await c.unpauseContainer('a');
    await c.killContainer('a');
    expect(t.calls.map((r) => r.path).toList(),
        ['/containers/a/restart', '/containers/a/pause', '/containers/a/unpause', '/containers/a/kill']);
  });

  test('rename posts the name query', () async {
    final t = FakeTransport.always(http.Response('', 204));
    await DockerApiClient(t).renameContainer('a', 'newname');
    expect(t.calls.last.path, '/containers/a/rename');
    expect(t.calls.last.query, {'name': 'newname'});
  });

  test('remove deletes with force + v query', () async {
    final t = FakeTransport.always(http.Response('', 204));
    await DockerApiClient(t).removeContainer('a', force: true, removeVolumes: true);
    expect(t.calls.last.method, 'DELETE');
    expect(t.calls.last.path, '/containers/a');
    expect(t.calls.last.query, {'force': 'true', 'v': 'true'});
  });

  test('a 409 on remove throws DockerApiException', () async {
    final t = FakeTransport.always(http.Response('', 409));
    expect(() => DockerApiClient(t).removeContainer('a'), throwsA(isA<DockerApiException>()));
  });

  test('a 500 on start throws DockerApiException', () async {
    final t = FakeTransport.always(http.Response('', 500));
    expect(() => DockerApiClient(t).startContainer('a'), throwsA(isA<DockerApiException>()));
  });

  test('304 is rejected for non-start/stop actions (start/stop-only no-op)', () async {
    final t = FakeTransport.always(http.Response('', 304));
    expect(() => DockerApiClient(t).restartContainer('a'), throwsA(isA<DockerApiException>()));
  });
}
