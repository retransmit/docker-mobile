/// A Docker container as returned by `GET /containers/json`.
///
/// Named `DockerContainer` (not `Container`) to avoid colliding with Flutter's
/// ubiquitous `Container` widget in any file that imports both.
class DockerContainer {
  final String id;
  final List<String> names;
  final String image;
  final String state;
  final String status;

  const DockerContainer({
    required this.id,
    required this.names,
    required this.image,
    required this.state,
    required this.status,
  });

  factory DockerContainer.fromJson(Map<String, dynamic> json) {
    return DockerContainer(
      id: json['Id'] as String,
      names: (json['Names'] as List?)?.cast<String>() ?? const [],
      image: json['Image'] as String? ?? '',
      state: json['State'] as String? ?? '',
      status: json['Status'] as String? ?? '',
    );
  }
}
