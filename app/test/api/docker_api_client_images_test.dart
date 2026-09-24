import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_api_client.dart';

import '../support/fake_transport.dart';

void main() {
  test('listImages parses the array', () async {
    final t = FakeTransport.always(
        http.Response('[{"Id":"a","RepoTags":["nginx:latest"],"Size":1,"Created":2}]', 200));
    final images = await DockerApiClient(t).listImages();
    expect(images.single.repoTags, ['nginx:latest']);
    expect(t.calls.single.path, '/images/json');
  });

  test('pullImage parses newline-delimited progress and queries fromImage+tag', () async {
    final pullChunks = [
      utf8.encode('{"status":"Pulling fs layer","id":"l1"}\n{"status":"Down'),
      utf8.encode('loading","id":"l1","progressDetail":{"current":5,"total":10}}\n'),
      utf8.encode('{"error":"nope"}\n'),
    ];
    final t = FakeTransport()..onPostStream(RegExp(r'/images/create'), (_) => Stream.fromIterable(pullChunks));
    final events = await DockerApiClient(t).pullImage('nginx', tag: '1.27').toList();

    expect(t.calls.last.path, '/images/create');
    expect(t.calls.last.query, {'fromImage': 'nginx', 'tag': '1.27'});
    expect(events.map((e) => e.status).toList(), ['Pulling fs layer', 'Downloading', '']);
    expect(events[1].current, 5);
    expect(events.last.error, 'nope');
  });

  test('tagImage posts repo+tag (201)', () async {
    final t = FakeTransport.always(http.Response('', 201));
    await DockerApiClient(t).tagImage('a', repo: 'myrepo', tag: 'v1');
    expect(t.calls.last.path, '/images/a/tag');
    expect(t.calls.last.query, {'repo': 'myrepo', 'tag': 'v1'});
  });

  test('removeImage deletes with force+noprune', () async {
    final t = FakeTransport.always(http.Response('', 200));
    await DockerApiClient(t).removeImage('a', force: true, noprune: true);
    expect(t.calls.last.method, 'DELETE');
    expect(t.calls.last.path, '/images/a');
    expect(t.calls.last.query, {'force': 'true', 'noprune': 'true'});
  });

  test('pruneImages sends dangling filter', () async {
    final t = FakeTransport.always(http.Response('', 200));
    await DockerApiClient(t).pruneImages(danglingOnly: false);
    expect(t.calls.last.path, '/images/prune');
    expect(t.calls.last.query, {'filters': '{"dangling":["false"]}'});
  });

  test('tagImage throws on non-201', () async {
    final t = FakeTransport.always(http.Response('', 409));
    expect(() => DockerApiClient(t).tagImage('a', repo: 'r'), throwsA(isA<DockerApiException>()));
  });
}
