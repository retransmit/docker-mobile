import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';
import 'package:docker_mobile/src/transport/timeouts.dart';

class _SpyClient extends http.BaseClient {
  final Stream<List<int>> body;
  final int status;
  http.BaseRequest? lastRequest;
  String? lastBody;
  // ignore: unused_element_parameter
  _SpyClient(this.body, {this.status = 200});
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastRequest = request;
    if (request is http.Request) lastBody = request.body;
    return http.StreamedResponse(body, status);
  }
}

/// Answers only once the test completes [response], like a registry handshake
/// that holds back the pull's response headers.
class _DelayedClient extends http.BaseClient {
  final response = Completer<http.StreamedResponse>();
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => response.future;
}

void main() {
  test('postStream POSTs with bearer + body and yields bytes', () async {
    final spy = _SpyClient(Stream.fromIterable([
      [1, 2],
      [3],
    ]));
    final t = AgentTransport(
      baseUri: Uri.parse('http://h:8080'),
      token: 'secret',
      streamClientFactory: () => spy,
    );

    final bytes = await t
        .postStream('/images/create', query: {'fromImage': 'nginx'}, body: {'k': 'v'})
        .expand((c) => c)
        .toList();

    expect(bytes, [1, 2, 3]);
    expect(spy.lastRequest!.method, 'POST');
    expect(spy.lastRequest!.headers['Authorization'], 'Bearer secret');
    expect(spy.lastRequest!.url.queryParameters['fromImage'], 'nginx');
    expect(jsonDecode(spy.lastBody!), {'k': 'v'});
  });

  test('pull headers that arrive after the stream header budget still deliver the body', () {
    fakeAsync((async) {
      final client = _DelayedClient();
      final t = AgentTransport(baseUri: Uri.parse('http://h:1'), token: 't', streamClientFactory: () => client);
      final got = <int>[];
      Object? err;
      t.postStream('/images/create').listen(got.addAll, onError: (Object e) => err = e);
      async.elapse(const Duration(seconds: 31));
      client.response.complete(http.StreamedResponse(Stream.value([1, 2]), 200));
      async.flushMicrotasks();
      expect(got, [1, 2]);
      expect(err, isNull);
    });
  });

  test('pull headers that never arrive time out after the long budget', () {
    fakeAsync((async) {
      final t = AgentTransport(
          baseUri: Uri.parse('http://h:1'), token: 't', streamClientFactory: () => _DelayedClient());
      Object? err;
      t.postStream('/images/create').listen((_) {}, onError: (Object e) => err = e);
      async.elapse(kLongRequestTimeout - const Duration(seconds: 1));
      expect(err, isNull);
      async.elapse(const Duration(seconds: 2));
      expect(err, isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.timeout));
    });
  });
}
