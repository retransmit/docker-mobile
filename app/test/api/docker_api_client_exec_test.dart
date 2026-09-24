import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_api_client.dart';

import '../support/fake_transport.dart';

void main() {
  test('createExec posts the exec config and returns the Id', () async {
    final t = FakeTransport.always(http.Response('{"Id":"e123"}', 201));
    final id = await DockerApiClient(t).createExec('c1', cmd: ['/bin/sh']);

    expect(id, 'e123');
    expect(t.posts.last.path, '/containers/c1/exec');
    final body = t.posts.last.body as Map<String, dynamic>;
    expect(body['Tty'], true);
    expect(body['AttachStdin'], true);
    expect(body['Cmd'], ['/bin/sh']);
  });

  test('resizeExec posts h and w as query params', () async {
    final t = FakeTransport.always(http.Response('', 200));
    await DockerApiClient(t).resizeExec('e1', cols: 120, rows: 40);
    expect(t.posts.last.path, '/exec/e1/resize');
    expect(t.posts.last.query, {'h': '40', 'w': '120'});
  });

  test('inspectExec parses running + exit code', () async {
    final t = FakeTransport.always(http.Response('{"Running":false,"ExitCode":0}', 200));
    final e = await DockerApiClient(t).inspectExec('e1');
    expect(e.running, isFalse);
    expect(e.exitCode, 0);
  });

  test('createExec throws on non-201', () async {
    final t = FakeTransport.always(http.Response('boom', 500));
    expect(() => DockerApiClient(t).createExec('c1', cmd: ['sh']),
        throwsA(isA<DockerApiException>()));
  });
}
