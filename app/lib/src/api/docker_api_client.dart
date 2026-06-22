import 'dart:convert';

import '../transport/transport.dart';
import 'models/docker_container.dart';
import 'models/container_inspect.dart';
import 'models/exec_inspect.dart';
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

  Future<String> createExec(String containerId, {required List<String> cmd, bool tty = true}) async {
    final resp = await transport.post('/containers/$containerId/exec', body: {
      'AttachStdin': true,
      'AttachStdout': true,
      'AttachStderr': true,
      'Tty': tty,
      'Cmd': cmd,
    });
    if (resp.statusCode != 201) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    return (jsonDecode(resp.body) as Map<String, dynamic>)['Id'] as String;
  }

  Future<ExecChannel> attachExec(String execId, {required int cols, required int rows}) =>
      transport.execAttach(execId, cols: cols, rows: rows);

  Future<void> resizeExec(String execId, {required int cols, required int rows}) async {
    final resp = await transport.post('/exec/$execId/resize', query: {'h': '$rows', 'w': '$cols'});
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
  }

  Future<ExecInspect> inspectExec(String execId) async {
    final resp = await transport.get('/exec/$execId/json');
    if (resp.statusCode != 200) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    return ExecInspect.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }
}
