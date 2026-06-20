import 'dart:convert';

import '../transport/transport.dart';
import 'models/docker_container.dart';
import 'models/container_inspect.dart';
import 'stdcopy.dart';

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

  Future<ContainerInspect> inspectContainer(String id) async {
    final resp = await transport.get('/containers/$id/json');
    if (resp.statusCode != 200) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    return ContainerInspect.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  /// Streams a container's logs. For non-TTY containers the bytes are stdcopy
  /// multiplexed and demuxed here; for TTY containers they pass through raw.
  Stream<LogChunk> streamContainerLogs(
    String id, {
    required bool tty,
    bool follow = true,
    int? tail,
    bool timestamps = false,
    bool stdout = true,
    bool stderr = true,
  }) {
    final query = {
      'follow': follow.toString(),
      'stdout': stdout.toString(),
      'stderr': stderr.toString(),
      'tail': tail?.toString() ?? 'all',
      'timestamps': timestamps.toString(),
    };
    final raw = transport.stream('/containers/$id/logs', query: query);
    return tty ? decodeRawLog(raw) : decodeStdcopy(raw);
  }
}
