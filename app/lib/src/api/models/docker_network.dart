class DockerNetwork {
  final String id;
  final String name;
  final String driver;
  final String scope;
  const DockerNetwork({required this.id, required this.name, required this.driver, required this.scope});

  factory DockerNetwork.fromJson(Map<String, dynamic> json) => DockerNetwork(
        id: json['Id'] as String? ?? '',
        name: json['Name'] as String? ?? '',
        driver: json['Driver'] as String? ?? '',
        scope: json['Scope'] as String? ?? '',
      );
}

class IpamConfig {
  final String? subnet;
  final String? gateway;
  final String? ipRange;
  const IpamConfig({this.subnet, this.gateway, this.ipRange});

  factory IpamConfig.fromJson(Map<String, dynamic> json) => IpamConfig(
        subnet: json['Subnet'] as String?,
        gateway: json['Gateway'] as String?,
        ipRange: json['IPRange'] as String?,
      );
}

class NetworkContainer {
  final String name;
  final String ipv4;
  const NetworkContainer({required this.name, required this.ipv4});
}

class NetworkDetail {
  final String id;
  final String name;
  final String driver;
  final String scope;
  final bool internal;
  final bool attachable;
  final bool enableIPv6;
  final String ipamDriver;
  final List<IpamConfig> ipam;
  final List<NetworkContainer> containers;
  final Map<String, String> labels;
  final Map<String, String> options;

  const NetworkDetail({
    required this.id,
    required this.name,
    required this.driver,
    required this.scope,
    required this.internal,
    required this.attachable,
    required this.enableIPv6,
    required this.ipamDriver,
    required this.ipam,
    required this.containers,
    required this.labels,
    required this.options,
  });

  factory NetworkDetail.fromJson(Map<String, dynamic> json) {
    final ipamObj = (json['IPAM'] as Map<String, dynamic>?) ?? const {};
    final config = (ipamObj['Config'] as List?) ?? const [];
    final containersObj = (json['Containers'] as Map<String, dynamic>?) ?? const {};
    return NetworkDetail(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      driver: json['Driver'] as String? ?? '',
      scope: json['Scope'] as String? ?? '',
      internal: json['Internal'] as bool? ?? false,
      attachable: json['Attachable'] as bool? ?? false,
      enableIPv6: json['EnableIPv6'] as bool? ?? false,
      ipamDriver: ipamObj['Driver'] as String? ?? '',
      ipam: config.map((c) => IpamConfig.fromJson(c as Map<String, dynamic>)).toList(),
      containers: containersObj.entries.map((e) {
        final v = (e.value as Map<String, dynamic>?) ?? const {};
        return NetworkContainer(
          name: v['Name'] as String? ?? '',
          ipv4: v['IPv4Address'] as String? ?? '',
        );
      }).toList(),
      labels: ((json['Labels'] as Map<String, dynamic>?) ?? const {}).map((k, v) => MapEntry(k, '$v')),
      options: ((json['Options'] as Map<String, dynamic>?) ?? const {}).map((k, v) => MapEntry(k, '$v')),
    );
  }
}
