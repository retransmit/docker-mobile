import 'dart:convert';

import '../transport/transport.dart';
import 'models/docker_container.dart';

class DockerApiException implements Exception {
  final int statusCode;
  final String body;
  const DockerApiException(this.statusCode, this.body);

  @override
  String toString() => 'DockerApiException($statusCode): $body';
}

/// The single Docker Engine API client used across all transports.
class DockerApiClient {
  final Transport transport;
  const DockerApiClient(this.transport);

  Future<List<DockerContainer>> listContainers({bool all = true}) async {
    final resp = await transport.get('/containers/json', query: {'all': all.toString()});
    if (resp.statusCode != 200) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    final decoded = jsonDecode(resp.body) as List<dynamic>;
    return decoded
        .map((e) => DockerContainer.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
