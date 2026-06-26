import 'dart:convert';

import 'package:http/http.dart' as http;

import '../transport/transport.dart';
import 'models/docker_container.dart';
import 'models/container_detail.dart';
import 'models/container_inspect.dart';
import 'models/container_create_config.dart';
import 'models/container_stats.dart';
import 'models/docker_event.dart';
import 'models/exec_inspect.dart';
import 'models/docker_image.dart';
import 'models/docker_network.dart';
import 'models/docker_volume.dart';
import 'models/image_detail.dart';
import 'models/pull_event.dart';
import 'models/system_info.dart';
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

  Future<String> createContainer(ContainerCreateConfig config, {String? name}) async {
    final resp = await transport.post(
      '/containers/create',
      query: (name == null || name.isEmpty) ? null : {'name': name},
      body: config.toJson(),
    );
    if (resp.statusCode != 201) throw DockerApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as Map<String, dynamic>)['Id'] as String;
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
    final buffer = <int>[]; // buffer BYTES so a multi-byte UTF-8 char split across chunks survives
    await for (final chunk in raw) {
      buffer.addAll(chunk);
      var nl = buffer.indexOf(0x0A);
      while (nl != -1) {
        final ev = _parsePullLine(utf8.decode(buffer.sublist(0, nl), allowMalformed: true));
        buffer.removeRange(0, nl + 1);
        if (ev != null) yield ev;
        nl = buffer.indexOf(0x0A);
      }
    }
    if (buffer.isNotEmpty) {
      final ev = _parsePullLine(utf8.decode(buffer, allowMalformed: true));
      if (ev != null) yield ev;
    }
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
        await transport.post('/images/prune',
            query: {'filters': jsonEncode({'dangling': [danglingOnly ? 'true' : 'false']})}),
        ok: const {200},
      );

  Future<List<DockerNetwork>> listNetworks() async {
    final resp = await transport.get('/networks');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as List).map((e) => DockerNetwork.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<NetworkDetail> inspectNetwork(String id) async {
    final resp = await transport.get('/networks/$id');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return NetworkDetail.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<String> createNetwork({
    required String name,
    String driver = 'bridge',
    bool internal = false,
    bool attachable = false,
    bool enableIPv6 = false,
    List<IpamConfig> ipam = const [],
    Map<String, String> labels = const {},
    Map<String, String> options = const {},
  }) async {
    final body = <String, dynamic>{
      'Name': name,
      'Driver': driver,
      'Internal': internal,
      'Attachable': attachable,
      'EnableIPv6': enableIPv6,
    };
    if (ipam.isNotEmpty) {
      body['IPAM'] = {
        'Driver': 'default',
        'Config': ipam.map((c) {
          final m = <String, dynamic>{};
          if (c.subnet != null && c.subnet!.isNotEmpty) m['Subnet'] = c.subnet;
          if (c.gateway != null && c.gateway!.isNotEmpty) m['Gateway'] = c.gateway;
          if (c.ipRange != null && c.ipRange!.isNotEmpty) m['IPRange'] = c.ipRange;
          return m;
        }).toList(),
      };
    }
    if (labels.isNotEmpty) body['Labels'] = labels;
    if (options.isNotEmpty) body['Options'] = options;

    final resp = await transport.post('/networks/create', body: body);
    if (resp.statusCode != 201) throw DockerApiException(resp.statusCode, resp.body);
    return (jsonDecode(resp.body) as Map<String, dynamic>)['Id'] as String;
  }

  Future<void> removeNetwork(String id) async =>
      _ensure(await transport.delete('/networks/$id'), ok: const {204});

  Future<void> pruneNetworks() async =>
      _ensure(await transport.post('/networks/prune'), ok: const {200});

  Future<List<DockerVolume>> listVolumes() async {
    final resp = await transport.get('/volumes');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    final list = (jsonDecode(resp.body) as Map<String, dynamic>)['Volumes'] as List? ?? const [];
    return list.map((e) => DockerVolume.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<DockerVolume> inspectVolume(String name) async {
    final resp = await transport.get('/volumes/$name');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return DockerVolume.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<DockerVolume> createVolume({
    required String name,
    String driver = 'local',
    Map<String, String> labels = const {},
    Map<String, String> driverOpts = const {},
  }) async {
    final body = <String, dynamic>{'Name': name, 'Driver': driver};
    if (labels.isNotEmpty) body['Labels'] = labels;
    if (driverOpts.isNotEmpty) body['DriverOpts'] = driverOpts;
    final resp = await transport.post('/volumes/create', body: body);
    if (resp.statusCode != 201) throw DockerApiException(resp.statusCode, resp.body);
    return DockerVolume.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> removeVolume(String name, {bool force = false}) async =>
      _ensure(await transport.delete('/volumes/$name', query: {'force': '$force'}), ok: const {204});

  Future<void> pruneVolumes() async =>
      _ensure(await transport.post('/volumes/prune'), ok: const {200});

  Future<SystemInfo> getInfo() async {
    final resp = await transport.get('/info');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return SystemInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<VersionInfo> getVersion() async {
    final resp = await transport.get('/version');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return VersionInfo.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<DiskUsage> getDiskUsage() async {
    final resp = await transport.get('/system/df');
    if (resp.statusCode != 200) throw DockerApiException(resp.statusCode, resp.body);
    return DiskUsage.fromJson(jsonDecode(resp.body) as Map<String, dynamic>);
  }

  Future<void> pruneContainers() async =>
      _ensure(await transport.post('/containers/prune'), ok: const {200});

  Future<void> pruneBuildCache() async =>
      _ensure(await transport.post('/build/prune'), ok: const {200});

  Future<void> systemPrune({bool allImages = false, bool includeVolumes = false}) async {
    await pruneContainers();
    await pruneNetworks();
    await pruneImages(danglingOnly: !allImages);
    await pruneBuildCache();
    if (includeVolumes) await pruneVolumes();
  }

  Stream<ContainerStats> streamContainerStats(String id) async* {
    final raw = transport.stream('/containers/$id/stats', query: {'stream': 'true'});
    final buffer = <int>[];
    await for (final chunk in raw) {
      buffer.addAll(chunk);
      var nl = buffer.indexOf(0x0A);
      while (nl != -1) {
        final line = utf8.decode(buffer.sublist(0, nl), allowMalformed: true).trim();
        buffer.removeRange(0, nl + 1);
        if (line.isNotEmpty) {
          try {
            yield ContainerStats.fromJson(jsonDecode(line) as Map<String, dynamic>);
          } catch (_) {
            // skip a malformed/partial line
          }
        }
        nl = buffer.indexOf(0x0A);
      }
    }
  }

  Stream<DockerEvent> streamEvents() async* {
    final raw = transport.stream('/events');
    final buffer = <int>[];
    await for (final chunk in raw) {
      buffer.addAll(chunk);
      var nl = buffer.indexOf(0x0A);
      while (nl != -1) {
        final line = utf8.decode(buffer.sublist(0, nl), allowMalformed: true).trim();
        buffer.removeRange(0, nl + 1);
        if (line.isNotEmpty) {
          try {
            yield DockerEvent.fromJson(jsonDecode(line) as Map<String, dynamic>);
          } catch (_) {
            // skip a malformed/partial line
          }
        }
        nl = buffer.indexOf(0x0A);
      }
    }
  }
}
