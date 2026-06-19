/// A Docker container as returned by `GET /containers/json`.
class Container {
  final String id;
  final List<String> names;
  final String image;
  final String state;
  final String status;

  const Container({
    required this.id,
    required this.names,
    required this.image,
    required this.state,
    required this.status,
  });

  factory Container.fromJson(Map<String, dynamic> json) {
    return Container(
      id: json['Id'] as String,
      names: (json['Names'] as List?)?.cast<String>() ?? const [],
      image: json['Image'] as String? ?? '',
      state: json['State'] as String? ?? '',
      status: json['Status'] as String? ?? '',
    );
  }
}
