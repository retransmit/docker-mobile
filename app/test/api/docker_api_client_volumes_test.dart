import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_api_client.dart';

import '../support/fake_transport.dart';

void main() {
  test('listVolumes parses the Volumes array', () async {
    final t = FakeTransport.always(
        http.Response('{"Volumes":[{"Name":"data","Driver":"local"}]}', 200));
    final vols = await DockerApiClient(t).listVolumes();
    expect(vols.single.name, 'data');
    expect(t.calls.single.path, '/volumes');
  });

  test('createVolume posts body, omitting empty Labels/DriverOpts, and returns the volume', () async {
    final t = FakeTransport.always(http.Response('{"Name":"data","Driver":"local"}', 201));
    final v = await DockerApiClient(t).createVolume(name: 'data', labels: const {'env': 'prod'});
    expect(v.name, 'data');
    expect(t.calls.last.path, '/volumes/create');
    final body = t.posts.last.body as Map<String, dynamic>;
    expect(body['Name'], 'data');
    expect(body['Driver'], 'local');
    expect(body['Labels'], {'env': 'prod'});
    expect(body.containsKey('DriverOpts'), isFalse);
  });

  test('removeVolume deletes with force', () async {
    final t = FakeTransport.always(http.Response('', 204));
    await DockerApiClient(t).removeVolume('data', force: true);
    expect(t.calls.last.method, 'DELETE');
    expect(t.calls.last.path, '/volumes/data');
    expect(t.calls.last.query, {'force': 'true'});
  });

  test('a 409 on remove throws DockerApiException', () async {
    final t = FakeTransport.always(http.Response('', 409));
    expect(() => DockerApiClient(t).removeVolume('data'), throwsA(isA<DockerApiException>()));
  });

  test('pruneVolumes posts to /volumes/prune', () async {
    final t = FakeTransport.always(http.Response('{"Name":"data","Driver":"local"}', 200));
    await DockerApiClient(t).pruneVolumes();
    expect(t.calls.last.path, '/volumes/prune');
  });
}
