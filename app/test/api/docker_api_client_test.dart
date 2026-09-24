import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/transport/transport.dart';

import '../support/fake_transport.dart';

void main() {
  test('listContainers decodes the array', () async {
    final t = FakeTransport.always(http.Response(
      '[{"Id":"a","Names":["/web"],"Image":"nginx","State":"running","Status":"Up"}]',
      200,
    ));
    final client = DockerApiClient(t);

    final containers = await client.listContainers();

    expect(t.lastPath, '/containers/json');
    expect(t.lastQuery, {'all': 'true'});
    expect(containers, hasLength(1));
    expect(containers.first.id, 'a');
    expect(containers.first.image, 'nginx');
  });

  test('listContainers throws DockerError on non-200', () async {
    final t = FakeTransport.always(http.Response('boom', 500));
    final client = DockerApiClient(t);
    expect(
      () => client.listContainers(),
      throwsA(isA<DockerError>().having((e) => e.statusCode, 'statusCode', 500)),
    );
  });

  test('listImages decodes the array (off main isolate)', () async {
    final t = FakeTransport.always(http.Response(
      '[{"Id":"sha256:abc","RepoTags":["nginx:latest"],"Size":1234,"Created":99}]',
      200,
    ));
    final client = DockerApiClient(t);

    final images = await client.listImages();

    expect(t.lastPath, '/images/json');
    expect(images, hasLength(1));
    expect(images.first.id, 'sha256:abc');
    expect(images.first.repoTags, ['nginx:latest']);
    expect(images.first.size, 1234);
  });

  test('listImages decodes a large body on a background isolate', () async {
    // Build a >64KB array so the client takes the Isolate.run decode path.
    final entries = List.generate(
      2000,
      (i) => '{"Id":"sha256:img$i","RepoTags":["repo$i:latest"],"Size":$i,"Created":0}',
    );
    final t = FakeTransport.always(http.Response('[${entries.join(',')}]', 200));
    final client = DockerApiClient(t);

    final images = await client.listImages();

    expect(images, hasLength(2000));
    expect(images.first.id, 'sha256:img0');
    expect(images.last.id, 'sha256:img1999');
    expect(images.last.size, 1999);
  });

  test('listImages throws DockerError on non-200', () async {
    final t = FakeTransport.always(http.Response('boom', 500));
    final client = DockerApiClient(t);
    expect(
      () => client.listImages(),
      throwsA(isA<DockerError>().having((e) => e.statusCode, 'statusCode', 500)),
    );
  });

  test('getDiskUsage decodes the object (off main isolate)', () async {
    final t = FakeTransport.always(http.Response(
      '{"Images":[{"Size":100}],"Containers":[{"SizeRw":20}],'
      '"Volumes":[{"UsageData":{"Size":5}}],"BuildCache":[{"Size":3}]}',
      200,
    ));
    final client = DockerApiClient(t);

    final df = await client.getDiskUsage();

    expect(t.lastPath, '/system/df');
    expect(df.images.size, 100);
    expect(df.containers.size, 20);
    expect(df.volumes.size, 5);
    expect(df.buildCache.size, 3);
    expect(df.total, 128);
  });

  test('getDiskUsage throws DockerError on non-200', () async {
    final t = FakeTransport.always(http.Response('boom', 500));
    final client = DockerApiClient(t);
    expect(
      () => client.getDiskUsage(),
      throwsA(isA<DockerError>().having((e) => e.statusCode, 'statusCode', 500)),
    );
  });

  test('non-200 becomes a DockerError with the parsed daemon message', () async {
    final t = FakeTransport.always(http.Response('{"message":"No such container: web"}', 404));
    final client = DockerApiClient(t);
    await expectLater(
      client.inspectContainer('web'),
      throwsA(isA<DockerError>()
          .having((e) => e.kind, 'kind', DockerErrorKind.notFound)
          .having((e) => e.statusCode, 'statusCode', 404)
          .having((e) => e.message, 'message', 'No such container: web')),
    );
  });

  test('paths are prefixed with the negotiated version', () async {
    final t = FakeTransport.always(http.Response('[]', 200));
    await DockerApiClient(t, apiVersion: '1.45').listContainers();
    expect(t.lastPath, '/v1.45/containers/json');
    expect(t.lastQuery, {'all': 'true'});
  });

  test('prefix normalises a leading v and whitespace', () async {
    final t = FakeTransport.always(http.Response('[]', 200));
    await DockerApiClient(t, apiVersion: ' v1.45 ').listContainers();
    expect(t.lastPath, '/v1.45/containers/json');
  });

  test('no prefix when apiVersion is null', () async {
    final t = FakeTransport.always(http.Response('[]', 200));
    await DockerApiClient(t).listContainers();
    expect(t.lastPath, '/containers/json');
  });

  test('ping and version are never prefixed', () async {
    final t = FakeTransport()
      ..onGet('/_ping', (_) => http.Response('OK', 200))
      ..onGet('/version', (_) => http.Response('{"Version":"27.0","ApiVersion":"1.46"}', 200));
    final client = DockerApiClient(t, apiVersion: '1.45');
    await client.ping();
    expect(t.lastPath, '/_ping');
    final v = await client.getVersion();
    expect(v.apiVersion, '1.46');
    expect(t.lastPath, '/version');
  });

  test('ping throws DockerError on non-200', () async {
    final t = FakeTransport()..onGet('/_ping', (_) => http.Response('nope', 500));
    expect(DockerApiClient(t).ping(),
        throwsA(isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.server)));
  });

  test('a hung request times out with DockerError.timeout', () {
    fakeAsync((async) {
      final t = FakeTransport()..hangOn('GET', '/containers/json');
      final client = DockerApiClient(t, requestTimeout: const Duration(seconds: 5));
      Object? error;
      client.listContainers().then((_) {}, onError: (Object e) { error = e; });
      async.elapse(const Duration(seconds: 4));
      expect(error, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(error, isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.timeout));
    });
  });

  test('requestTimeout null disables the timeout', () {
    fakeAsync((async) {
      final t = FakeTransport()..hangOn('GET', '/containers/json');
      final client = DockerApiClient(t, requestTimeout: null);
      Object? error;
      client.listContainers().then((_) {}, onError: (Object e) { error = e; });
      async.elapse(const Duration(minutes: 5));
      expect(error, isNull);
      expect(async.pendingTimers, isEmpty);
    });
  });

  test('transport exceptions are wrapped for buffered calls and streams', () async {
    final t = FakeTransport()
      ..throwOn('GET', RegExp('.*'), const SocketException('refused'))
      ..throwOn('STREAM', '/events', const SocketException('gone'));
    final client = DockerApiClient(t);
    expect(client.listContainers(),
        throwsA(isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.network)));
    expect(client.streamEvents().first,
        throwsA(isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.network)));
  });

  test('streams are prefixed too', () async {
    final t = FakeTransport()..onStream(RegExp('.*'), (_) => const Stream.empty());
    await DockerApiClient(t, apiVersion: '1.45').streamEvents().toList();
    expect(t.lastPath, '/v1.45/events');
  });

  test('long-running calls get the long budget', () {
    fakeAsync((async) {
      final t = FakeTransport()..hangOn('POST', '/containers/c1/stop');
      final client = DockerApiClient(t);
      Object? error;
      client.stopContainer('c1').then((_) {}, onError: (Object e) { error = e; });
      async.elapse(const Duration(minutes: 5));
      expect(error, isNull);
      async.elapse(const Duration(minutes: 6));
      expect(error, isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.timeout));
    });
  });

  test('every long-running call outlives the default budget but not the long one', () {
    final calls = <String, Future<void> Function(DockerApiClient)>{
      'stopContainer': (c) => c.stopContainer('c1'),
      'restartContainer': (c) => c.restartContainer('c1'),
      'removeContainer': (c) => c.removeContainer('c1'),
      'pruneContainers': (c) => c.pruneContainers(),
      'removeImage': (c) => c.removeImage('i1'),
      'pruneImages': (c) => c.pruneImages(),
      'pruneNetworks': (c) => c.pruneNetworks(),
      'removeVolume': (c) => c.removeVolume('v1'),
      'pruneVolumes': (c) => c.pruneVolumes(),
      'pruneBuildCache': (c) => c.pruneBuildCache(),
      'getDiskUsage': (c) => c.getDiskUsage(),
    };
    for (final entry in calls.entries) {
      fakeAsync((async) {
        final t = FakeTransport()
          ..hangOn('GET', RegExp('.*'))
          ..hangOn('POST', RegExp('.*'))
          ..hangOn('DELETE', RegExp('.*'));
        final client = DockerApiClient(t, requestTimeout: const Duration(seconds: 5));
        Object? error;
        entry.value(client).then((_) {}, onError: (Object e) { error = e; });
        async.elapse(const Duration(minutes: 9));
        expect(error, isNull, reason: entry.key);
        async.elapse(const Duration(minutes: 2));
        expect(error, isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.timeout), reason: entry.key);
      });
    }
  });

  test('default budget still applies to a call without the escape hatch', () {
    fakeAsync((async) {
      final t = FakeTransport()..hangOn('POST', '/containers/c1/kill');
      final client = DockerApiClient(t, requestTimeout: const Duration(seconds: 5));
      Object? error;
      client.killContainer('c1').then((_) {}, onError: (Object e) { error = e; });
      async.elapse(const Duration(seconds: 6));
      expect(error, isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.timeout));
    });
  });

  test('an apiVersion that normalises to empty leaves paths unprefixed', () async {
    final t = FakeTransport.always(http.Response('[]', 200));
    await DockerApiClient(t, apiVersion: ' v ').listContainers();
    expect(t.lastPath, '/containers/json');
  });

  test('postStream paths are prefixed and errors wrapped', () async {
    final t = FakeTransport()..onPostStream(RegExp('.*'), (_) => const Stream.empty());
    final client = DockerApiClient(t, apiVersion: '1.45');
    await client.pullImage('nginx').toList();
    expect(t.lastPath, '/v1.45/images/create');

    t.throwOn('POSTSTREAM', RegExp('.*'), const SocketException('gone'));
    await expectLater(client.pullImage('nginx').first,
        throwsA(isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.network)));
  });

  test('a synchronous transport throw on stream is wrapped', () async {
    await expectLater(DockerApiClient(_SyncThrowingTransport()).streamEvents().first,
        throwsA(isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.unknown)));
  });
}

/// A transport whose [stream] throws synchronously instead of returning an
/// erroring stream, which no FakeTransport rule can do.
class _SyncThrowingTransport implements Transport {
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => throw StateError('boom');

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) => throw UnimplementedError();

  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) =>
      throw UnimplementedError();

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) => throw UnimplementedError();

  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) =>
      throw UnimplementedError();

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();

  @override
  Future<void> close() => throw UnimplementedError();
}
