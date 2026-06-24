class DockerVolume {
  final String name;
  final String driver;
  final String mountpoint;
  final String createdAt;
  final String scope;
  final Map<String, String> labels;
  final Map<String, String> options;

  const DockerVolume({
    required this.name,
    required this.driver,
    required this.mountpoint,
    required this.createdAt,
    required this.scope,
    required this.labels,
    required this.options,
  });

  factory DockerVolume.fromJson(Map<String, dynamic> json) => DockerVolume(
        name: json['Name'] as String? ?? '',
        driver: json['Driver'] as String? ?? '',
        mountpoint: json['Mountpoint'] as String? ?? '',
        createdAt: json['CreatedAt'] as String? ?? '',
        scope: json['Scope'] as String? ?? '',
        labels: ((json['Labels'] as Map<String, dynamic>?) ?? const {}).map((k, v) => MapEntry(k, '$v')),
        options: ((json['Options'] as Map<String, dynamic>?) ?? const {}).map((k, v) => MapEntry(k, '$v')),
      );
}
