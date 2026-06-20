/// Subset of `GET /containers/{id}/json` needed by the log viewer.
class ContainerInspect {
  final String id;
  final String name;
  final String image;
  final String state;
  final bool tty;

  const ContainerInspect({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.tty,
  });

  factory ContainerInspect.fromJson(Map<String, dynamic> json) {
    final config = (json['Config'] as Map<String, dynamic>?) ?? const {};
    final stateObj = (json['State'] as Map<String, dynamic>?) ?? const {};
    final rawName = json['Name'] as String? ?? '';
    return ContainerInspect(
      id: json['Id'] as String? ?? '',
      name: rawName.startsWith('/') ? rawName.substring(1) : rawName,
      image: config['Image'] as String? ?? '',
      state: stateObj['Status'] as String? ?? '',
      tty: config['Tty'] as bool? ?? false,
    );
  }
}
