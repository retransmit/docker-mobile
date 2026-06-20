import 'package:http/http.dart' as http;

/// Thrown into a [Transport.stream] when the daemon responds with a non-200.
class TransportException implements Exception {
  final int statusCode;
  final String body;
  const TransportException(this.statusCode, this.body);

  @override
  String toString() => 'TransportException($statusCode): $body';
}

/// Moves Docker Engine API requests to a daemon. Phase 0/1A implement only
/// [AgentTransport]; TCP+TLS and SSH transports arrive in sub-project D.
abstract class Transport {
  Future<http.Response> get(String path, {Map<String, String>? query});

  /// Opens a streaming GET (e.g. `/containers/{id}/logs?follow=true`) and emits
  /// the raw response bytes. Canceling the returned stream's subscription MUST
  /// close the underlying connection.
  Stream<List<int>> stream(String path, {Map<String, String>? query});
}
