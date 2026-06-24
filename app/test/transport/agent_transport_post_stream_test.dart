import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/agent_transport.dart';

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
}
