import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';

void main() {
  test('sends bearer token and builds the right URL', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response('[]', 200);
    });
    final t = AgentTransport(
      baseUri: Uri.parse('http://10.0.0.5:8080'),
      token: 'secret',
      client: mock,
    );

    final resp = await t.get('/containers/json', query: {'all': 'true'});

    expect(resp.statusCode, 200);
    expect(captured.headers['Authorization'], 'Bearer secret');
    expect(captured.url.path, '/containers/json');
    expect(captured.url.queryParameters['all'], 'true');
    expect(captured.url.host, '10.0.0.5');
    expect(captured.url.port, 8080);
  });
}
