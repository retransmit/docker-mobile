class ContainerStateInfo {
  final String status;
  final bool running;
  final bool paused;
  final int? exitCode;
  final String? startedAt;
  const ContainerStateInfo({
    required this.status,
    required this.running,
    required this.paused,
    this.exitCode,
    this.startedAt,
  });

  factory ContainerStateInfo.fromJson(Map<String, dynamic> json) => ContainerStateInfo(
        status: json['Status'] as String? ?? '',
        running: json['Running'] as bool? ?? false,
        paused: json['Paused'] as bool? ?? false,
        exitCode: json['ExitCode'] as int?,
        startedAt: json['StartedAt'] as String?,
      );
}

class PortMapping {
  final String? ip;
  final int? privatePort;
  final int? publicPort;
  final String type;
  const PortMapping({this.ip, this.privatePort, this.publicPort, required this.type});
}

class MountInfo {
  final String source;
  final String destination;
  final String mode;
  final bool rw;
  const MountInfo({required this.source, required this.destination, required this.mode, required this.rw});

  factory MountInfo.fromJson(Map<String, dynamic> json) => MountInfo(
        source: json['Source'] as String? ?? '',
        destination: json['Destination'] as String? ?? '',
        mode: json['Mode'] as String? ?? '',
        rw: json['RW'] as bool? ?? false,
      );
}

/// Rich view of `GET /containers/{id}/json` for the detail screen.
class ContainerDetail {
  final String id;
  final String name;
  final String image;
  final String command;
  final String created;
  final ContainerStateInfo state;
  final List<PortMapping> ports;
  final List<MountInfo> mounts;
  final List<String> env;
  final String restartPolicy;
  final List<String> networks;

  const ContainerDetail({
    required this.id,
    required this.name,
    required this.image,
    required this.command,
    required this.created,
    required this.state,
    required this.ports,
    required this.mounts,
    required this.env,
    required this.restartPolicy,
    required this.networks,
  });

  factory ContainerDetail.fromJson(Map<String, dynamic> json) {
    final config = (json['Config'] as Map<String, dynamic>?) ?? const {};
    final stateObj = (json['State'] as Map<String, dynamic>?) ?? const {};
    final hostConfig = (json['HostConfig'] as Map<String, dynamic>?) ?? const {};
    final netSettings = (json['NetworkSettings'] as Map<String, dynamic>?) ?? const {};
    final rawName = json['Name'] as String? ?? '';
    final cmd = (config['Cmd'] as List?)?.cast<String>() ?? const <String>[];
    return ContainerDetail(
      id: json['Id'] as String? ?? '',
      name: rawName.startsWith('/') ? rawName.substring(1) : rawName,
      image: config['Image'] as String? ?? '',
      command: cmd.join(' '),
      created: json['Created'] as String? ?? '',
      state: ContainerStateInfo.fromJson(stateObj),
      ports: _parsePorts(netSettings['Ports'] as Map<String, dynamic>?),
      mounts: ((json['Mounts'] as List?) ?? const [])
          .map((m) => MountInfo.fromJson(m as Map<String, dynamic>))
          .toList(),
      env: (config['Env'] as List?)?.cast<String>() ?? const [],
      restartPolicy: (hostConfig['RestartPolicy'] as Map<String, dynamic>?)?['Name'] as String? ?? '',
      networks: (netSettings['Networks'] as Map<String, dynamic>?)?.keys.toList() ?? const [],
    );
  }

  static List<PortMapping> _parsePorts(Map<String, dynamic>? ports) {
    if (ports == null) return const [];
    final result = <PortMapping>[];
    ports.forEach((key, value) {
      final parts = key.split('/');
      final priv = int.tryParse(parts.first);
      final type = parts.length > 1 ? parts[1] : 'tcp';
      final bindings = value as List?;
      if (bindings == null || bindings.isEmpty) {
        result.add(PortMapping(privatePort: priv, type: type));
      } else {
        for (final b in bindings) {
          final bm = b as Map<String, dynamic>;
          result.add(PortMapping(
            ip: bm['HostIp'] as String?,
            privatePort: priv,
            publicPort: int.tryParse(bm['HostPort'] as String? ?? ''),
            type: type,
          ));
        }
      }
    });
    return result;
  }
}
