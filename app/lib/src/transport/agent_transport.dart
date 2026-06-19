import 'package:http/http.dart' as http;

import 'transport.dart';

/// Talks to the docker-mobile agent over HTTP(S) with a bearer token.
class AgentTransport implements Transport {
  final Uri baseUri;
  final String token;
  final http.Client _client;

  AgentTransport({
    required this.baseUri,
    required this.token,
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    return _client.get(uri, headers: {'Authorization': 'Bearer $token'});
  }
}
