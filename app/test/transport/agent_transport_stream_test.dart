import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
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

  test('stream errors with TransportException on non-200', () async {
    final spy = _SpyClient(Stream.value(utf8.encode('nope')), status: 404);
    final t = AgentTransport(
      baseUri: Uri.parse('http://h:8080'),
      token: 's',
      streamClientFactory: () => spy,
    );
    await expectLater(t.stream('/x'), emitsError(isA<TransportException>()));
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
}
