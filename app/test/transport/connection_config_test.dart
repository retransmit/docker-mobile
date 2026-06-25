import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';
import 'package:docker_mobile/src/transport/tls_transport.dart';
import 'package:docker_mobile/src/transport/tls_security.dart';
import 'package:docker_mobile/src/transport/connection_config.dart';

void main() {
  final cert = File('test/fixtures/client-cert.pem').readAsStringSync();
  final key = File('test/fixtures/client-key.pem').readAsStringSync();

  test('AgentConnectionConfig builds an AgentTransport', () {
    final t = AgentConnectionConfig(baseUri: Uri.parse('http://h:8080'), token: 'tok').build();
    expect(t, isA<AgentTransport>());
  });

  test('TlsConnectionConfig builds a TlsTransport from valid PEM', () {
    final t = TlsConnectionConfig(
      host: '10.0.0.5', port: 2376, clientCertPem: cert, clientKeyPem: key,
    ).build();
    expect(t, isA<TlsTransport>());
  });

  test('TlsConnectionConfig surfaces malformed PEM as TlsConfigException', () {
    expect(
      () => TlsConnectionConfig(host: 'h', port: 2376, clientCertPem: 'nope', clientKeyPem: 'nope').build(),
      throwsA(isA<TlsConfigException>()),
    );
  });
}
