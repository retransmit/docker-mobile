import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';

void main() {
  test('delete sends DELETE with bearer + query', () async {
    late http.Request captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response('', 204);
    });
    final t = AgentTransport(baseUri: Uri.parse('http://h:8080'), token: 'secret', client: mock);

    final resp = await t.delete('/containers/c', query: {'force': 'true', 'v': 'true'});

    expect(resp.statusCode, 204);
    expect(captured.method, 'DELETE');
    expect(captured.headers['Authorization'], 'Bearer secret');
    expect(captured.url.path, '/containers/c');
    expect(captured.url.queryParameters, {'force': 'true', 'v': 'true'});
  });
}
