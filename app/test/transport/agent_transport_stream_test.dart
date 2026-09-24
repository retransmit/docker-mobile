import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';

class _SpyClient extends http.BaseClient {
  final Stream<List<int>> body;
  final int status;
  bool closed = false;
  http.BaseRequest? lastRequest;
  _SpyClient(this.body, {this.status = 200});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    return http.StreamedResponse(body, status);
  }

  @override
  void close() {
    closed = true;
    super.close();
  }
}

class _HangingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => Completer<http.StreamedResponse>().future;
}

class _ThrowingClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async => throw const SocketException('refused');
}

void main() {
  test('stream yields bytes, sends bearer header, builds URL+query', () async {
    final spy = _SpyClient(Stream.fromIterable([
      [1, 2, 3],
      [4, 5],
    ]));
    final t = AgentTransport(
      baseUri: Uri.parse('http://10.0.0.5:8080'),
      token: 'secret',
      streamClientFactory: () => spy,
    );

    final bytes = await t
        .stream('/containers/x/logs', query: {'follow': 'true'})
        .expand((c) => c)
        .toList();

    expect(bytes, [1, 2, 3, 4, 5]);
    expect(spy.lastRequest!.headers['Authorization'], 'Bearer secret');
    expect(spy.lastRequest!.url.path, '/containers/x/logs');
    expect(spy.lastRequest!.url.queryParameters['follow'], 'true');
  });

  test('stream errors with DockerError on non-200', () async {
    final spy = _SpyClient(Stream.value(utf8.encode('nope')), status: 404);
    final t = AgentTransport(
      baseUri: Uri.parse('http://10.0.0.5:8080'),
      token: 'secret',
      streamClientFactory: () => spy,
    );
    await expectLater(
      t.stream('/x'),
      emitsError(isA<DockerError>().having((e) => e.statusCode, 'statusCode', 404)),
    );
  });

  test('canceling the subscription closes the client (no leaked follow)', () async {
    final neverEnds = StreamController<List<int>>();
    final spy = _SpyClient(neverEnds.stream);
    final t = AgentTransport(
      baseUri: Uri.parse('http://h:8080'),
      token: 's',
      streamClientFactory: () => spy,
    );

    final sub = t.stream('/x').listen((_) {});
    await Future<void>.delayed(Duration.zero); // let onListen run send()
    await sub.cancel();

    expect(spy.closed, isTrue);
    await neverEnds.close();
  });

  test('stream times out when headers never arrive', () {
    fakeAsync((async) {
      final t = AgentTransport(
        baseUri: Uri.parse('http://h:1'),
        token: 't',
        streamClientFactory: () => _HangingClient(),
        streamHeaderTimeout: const Duration(seconds: 5),
      );
      Object? err;
      t.stream('/x').listen((_) {}, onError: (Object e) => err = e);
      async.elapse(const Duration(seconds: 4));
      expect(err, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(err, isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.timeout));
    });
  });

  test('a slow stream body is never cut by the header timeout', () {
    fakeAsync((async) {
      final body = StreamController<List<int>>();
      final t = AgentTransport(
        baseUri: Uri.parse('http://h:1'),
        token: 't',
        streamClientFactory: () => _SpyClient(body.stream),
        streamHeaderTimeout: const Duration(seconds: 1),
      );
      final got = <int>[];
      Object? err;
      t.stream('/x').listen(got.addAll, onError: (Object e) => err = e);
      async.flushMicrotasks();
      body.add([1]);
      async.elapse(const Duration(seconds: 30));
      body.add([2]);
      async.flushMicrotasks();
      expect(got, [1, 2]);
      expect(err, isNull);
    });
  });

  test('socket failures surface as DockerError.network', () async {
    final t = AgentTransport(
      baseUri: Uri.parse('http://h:1'),
      token: 't',
      streamClientFactory: () => _ThrowingClient(),
    );
    await expectLater(
      t.stream('/x'),
      emitsError(isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.network)),
    );
  });
}
