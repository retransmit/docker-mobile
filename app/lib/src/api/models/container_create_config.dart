class PortMapping {
  final String containerPort;
  final String protocol; // 'tcp' | 'udp'
  final String hostPort;
  const PortMapping({required this.containerPort, required this.protocol, required this.hostPort});
}

/// Builds the JSON body for POST /containers/create. Empty sections are omitted
/// (and HostConfig is omitted entirely when it would be empty).
class ContainerCreateConfig {
  final String image;
  final List<String> cmd;
  final Map<String, String> env;
  final List<PortMapping> ports;
  final Map<String, String> binds; // host -> container
  final String? restartPolicy;
  final Map<String, String> labels;
  final String? network;
  final int? memoryBytes;
  final double? cpus;

  const ContainerCreateConfig({
    required this.image,
    this.cmd = const [],
    this.env = const {},
    this.ports = const [],
    this.binds = const {},
    this.restartPolicy,
    this.labels = const {},
    this.network,
    this.memoryBytes,
    this.cpus,
  });

  /// Whitespace-split (quoted args are out of scope; documented in the form).
  static List<String> parseCommand(String s) =>
      s.trim().isEmpty ? const [] : s.trim().split(RegExp(r'\s+'));

  Map<String, dynamic> toJson() {
    final json = <String, dynamic>{'Image': image};
    if (cmd.isNotEmpty) json['Cmd'] = cmd;
    if (env.isNotEmpty) json['Env'] = [for (final e in env.entries) '${e.key}=${e.value}'];
    if (labels.isNotEmpty) json['Labels'] = labels;
    if (ports.isNotEmpty) {
      json['ExposedPorts'] = {for (final p in ports) '${p.containerPort}/${p.protocol}': <String, dynamic>{}};
    }

    final hostConfig = <String, dynamic>{};
    if (ports.isNotEmpty) {
      hostConfig['PortBindings'] = {
        for (final p in ports)
          '${p.containerPort}/${p.protocol}': [
            {'HostPort': p.hostPort}
          ]
      };
    }
    if (binds.isNotEmpty) hostConfig['Binds'] = [for (final b in binds.entries) '${b.key}:${b.value}'];
    if (restartPolicy != null && restartPolicy!.isNotEmpty) hostConfig['RestartPolicy'] = {'Name': restartPolicy};
    if (network != null && network!.isNotEmpty) hostConfig['NetworkMode'] = network;
    if (memoryBytes != null) hostConfig['Memory'] = memoryBytes;
    if (cpus != null) hostConfig['NanoCpus'] = (cpus! * 1e9).round();
    if (hostConfig.isNotEmpty) json['HostConfig'] = hostConfig;
    return json;
  }
}
