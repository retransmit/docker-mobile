import 'dart:convert';

import 'package:http/http.dart' as http;

import '../transport/transport.dart';
import 'models/docker_container.dart';
import 'models/container_detail.dart';
import 'models/container_inspect.dart';
import 'models/exec_inspect.dart';
import 'models/docker_image.dart';
import 'models/image_detail.dart';
import 'models/pull_event.dart';
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

  void _ensure(http.Response resp, {Set<int> ok = const {204}}) {
    if (!ok.contains(resp.statusCode)) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
  }

  Future<ContainerDetail> inspectContainerDetail(String id) async {
    final resp = await transport.get('/containers/$id/json');
    if (resp.statusCode != 200) {
      throw DockerApiException(resp.statusCode, resp.body);
    }
    return ContainerDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> startContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/start'), ok: const {204, 304});

  Future<void> stopContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/stop'), ok: const {204, 304});

  Future<void> restartContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/restart'));

  Future<void> pauseContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/pause'));

  Future<void> unpauseContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/unpause'));

  Future<void> killContainer(String id) async =>
      _ensure(await transport.post('/containers/$id/kill'));

  Future<void> renameContainer(String id, String newName) async =>
      _ensure(await transport.post('/containers/$id/rename', query: {'name': newName}));

  Future<void> removeContainer(String id, {bool force = false, bool removeVolumes = false}) async =>
      _ensure(await transport.delete('/containers/$id', query: {'force': '$force', 'v': '$removeVolumes'}));

  Future<List<DockerImage>> listImages() async {
    final resp = await transport.get('/images/json');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as List).map((e) => DockerImage.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<ImageDetail> inspectImage(String id) async {
    final resp = await transport.get('/images/$id/json');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return ImageDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<List<ImageHistoryLayer>> imageHistory(String id) async {
    final resp = await transport.get('/images/$id/history');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as List).map((e) => ImageHistoryLayer.fromJson(e as Map<String, dynamic>)).toList();
  }

  Stream<PullEvent> pullImage(String image, {String tag = 'latest'}) async* {
    final raw = transport.postStream('/images/create', query: {'fromImage': image, 'tag': tag});
    var buffer = '';
    await for (final chunk in raw) {
      buffer += utf8.decode(chunk, allowMalformed: true);
      final lines = buffer.split('\n');
      buffer = lines.removeLast();
      for (final line in lines) {
        final ev = _parsePullLine(line);
        if (ev != null) yield ev;
      }
    }
    final ev = _parsePullLine(buffer);
    if (ev != null) yield ev;
  }

  PullEvent? _parsePullLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return null;
    try {
      return PullEvent.fromJson(jsonDecode(t) as Map<String, dynamic>);
    } catch (_) {
      return null; // skip a fragment that isn't a complete JSON object
    }
  }

  Future<void> tagImage(String id, {required String repo, String tag = 'latest'}) async =>
      _ensure(await transport.post('/images/$id/tag', query: {'repo': repo, 'tag': tag}), ok: const {201});

  Future<void> removeImage(String id, {bool force = false, bool noprune = false}) async =>
      _ensure(await transport.delete('/images/$id', query: {'force': '$force', 'noprune': '$noprune'}), ok: const {200});

  Future<void> pruneImages({bool danglingOnly = true}) async => _ensure(
        await transport.post('/images/prune', query: {'filters': '{"dangling":["${danglingOnly ? 'true' : 'false'}"]}'}),
        ok: const {200},
      );
}
