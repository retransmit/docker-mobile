import 'dart:convert';

import 'package:http/io_client.dart';

import 'agent_transport.dart';
import 'tls_security.dart';
import 'tls_transport.dart';
import 'transport.dart';

/// A connection the user configured; [build] produces a live [Transport].
sealed class ConnectionConfig {
  Transport build();
}

class AgentConnectionConfig extends ConnectionConfig {
  final Uri baseUri;
  final String token;
  AgentConnectionConfig({required this.baseUri, required this.token});

  @override
  Transport build() => AgentTransport(baseUri: baseUri, token: token);
}

class TlsConnectionConfig extends ConnectionConfig {
  final String host;
  final int port;
  final String clientCertPem;
  final String clientKeyPem;
  final String? caPem;
  final bool insecure;

  TlsConnectionConfig({
    required this.host,
    required this.port,
    required this.clientCertPem,
    required this.clientKeyPem,
    this.caPem,
    this.insecure = false,
  });

  @override
  Transport build() {
    final httpClient = buildTlsHttpClient(
      clientCertPem: utf8.encode(clientCertPem),
      clientKeyPem: utf8.encode(clientKeyPem),
      caPem: caPem == null ? null : utf8.encode(caPem!),
      insecure: insecure,
    );
    final baseUri = Uri(scheme: 'https', host: host, port: port);
    return TlsTransport(
      baseUri: baseUri,
      client: IOClient(httpClient),
      execOpener: (id, cols, rows) => hijackExec(httpClient, baseUri, id, cols, rows),
    );
  }
}
