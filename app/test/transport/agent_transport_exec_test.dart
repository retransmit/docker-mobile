import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';

void main() {
  test('post sends JSON body and bearer header', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response('{"Id":"x"}', 201);
    });
    final t = AgentTransport(
      baseUri: Uri.parse('http://h:8080'),
      token: 'secret',
      client: mock,
    );

    final resp = await t.post('/containers/c/exec', body: {'Cmd': ['sh']});

    expect(resp.statusCode, 201);
    expect(captured.method, 'POST');
    expect(captured.headers['Authorization'], 'Bearer secret');
    expect(jsonDecode(captured.body), {'Cmd': ['sh']});
  });

  test('post forwards query params (resize)', () async {
    late Uri url;
    final mock = MockClient((req) async {
      url = req.url;
      return http.Response('', 200);
    });
    final t = AgentTransport(baseUri: Uri.parse('http://h:8080'), token: 's', client: mock);
    await t.post('/exec/e/resize', query: {'h': '24', 'w': '80'});
    expect(url.path, '/exec/e/resize');
    expect(url.queryParameters, {'h': '24', 'w': '80'});
  });

  test('execAttach connects, echoes, and carries the bearer header', () async {
    // Local WebSocket echo server that records the handshake Authorization.
    String? auth;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      auth = req.headers.value('authorization');
      final ws = await WebSocketTransformer.upgrade(req);
      ws.listen((data) => ws.add(data)); // echo
    });
    addTearDown(() => server.close(force: true));

    final t = AgentTransport(
      baseUri: Uri.parse('http://${server.address.host}:${server.port}'),
      token: 'secret',
    );
    final channel = await t.execAttach('e1', cols: 80, rows: 24);
    final received = <int>[];
    final sub = channel.output.listen(received.addAll);

    channel.send(utf8.encode('ping'));
    await Future<void>.delayed(const Duration(milliseconds: 100));

    expect(utf8.decode(received), 'ping');
    expect(auth, 'Bearer secret');
    await sub.cancel();
    await channel.close();
  });
}
