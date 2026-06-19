import 'package:http/http.dart' as http;

/// Moves Docker Engine API requests to a daemon. Phase 0 implements only
/// [AgentTransport]; TCP+TLS and SSH transports arrive in Phase 1.
abstract class Transport {
  Future<http.Response> get(String path, {Map<String, String>? query});
}
