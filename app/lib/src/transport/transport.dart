import 'package:http/http.dart' as http;

/// Thrown into a [Transport.stream] when the daemon responds with a non-200.
class TransportException implements Exception {
  final int statusCode;
  final String body;
  const TransportException(this.statusCode, this.body);

  @override
  String toString() => 'TransportException($statusCode): $body';
}

/// A live bidirectional exec session (WebSocket over the agent in 1B).
abstract class ExecChannel {
  Stream<List<int>> get output;
  void send(List<int> data);
  Future<void> close();
}

/// Moves Docker Engine API requests to a daemon. 1B implements only
/// [AgentTransport]; TCP+TLS and SSH transports arrive in sub-project D.
abstract class Transport {
  Future<http.Response> get(String path, {Map<String, String>? query});

  /// Streaming GET (logs/stats/events). Canceling closes the connection.
  Stream<List<int>> stream(String path, {Map<String, String>? query});

  /// POST with an optional JSON body and/or query params.
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers});

  /// Open an interactive exec session by WebSocket bridge.
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows});
}
