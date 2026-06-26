import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/agent_transport.dart';
import 'package:docker_mobile/src/transport/tls_transport.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_transport.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';

class _FakeClient extends http.BaseClient {
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      http.StreamedResponse(const Stream.empty(), 200);
  @override
  void close() {
    closed = true;
    super.close();
  }
}

void main() {
  test('AgentTransport.close() closes its client', () async {
    final c = _FakeClient();
    await AgentTransport(baseUri: Uri.parse('http://h:8080'), token: 't', client: c).close();
    expect(c.closed, isTrue);
  });

  test('TlsTransport.close() closes its client', () async {
    final c = _FakeClient();
    await TlsTransport(baseUri: Uri.parse('https://h:2376'), client: c).close();
    expect(c.closed, isTrue);
  });

  test('SshTransport.close() invokes onClose (and is null-safe without it)', () async {
    var closed = false;
    await SshTransport(
      openDuplex: () async => Duplex(input: const Stream.empty(), add: (_) {}, close: () async {}),
      onClose: () async => closed = true,
    ).close();
    expect(closed, isTrue);

    // No onClose -> close() is a harmless no-op.
    await SshTransport(
      openDuplex: () async => Duplex(input: const Stream.empty(), add: (_) {}, close: () async {}),
    ).close();
  });
}
