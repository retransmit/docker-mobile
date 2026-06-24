/// One layer from `GET /images/{id}/history`.
class ImageHistoryLayer {
  final String id;
  final int created;
  final String createdBy;
  final int size;
  final List<String> tags;

  const ImageHistoryLayer({
    required this.id,
    required this.created,
    required this.createdBy,
    required this.size,
    required this.tags,
  });

  factory ImageHistoryLayer.fromJson(Map<String, dynamic> json) => ImageHistoryLayer(
        id: json['Id'] as String? ?? '',
        created: (json['Created'] as num?)?.toInt() ?? 0,
        createdBy: json['CreatedBy'] as String? ?? '',
        size: (json['Size'] as num?)?.toInt() ?? 0,
        tags: (json['Tags'] as List?)?.cast<String>() ?? const [],
      );
}

/// Subset of `GET /images/{id}/json`.
class ImageDetail {
  final String id;
  final List<String> repoTags;
  final String architecture;
  final String os;
  final int size;
  final String created;
  final List<String> env;
  final List<String> exposedPorts;

  const ImageDetail({
    required this.id,
    required this.repoTags,
    required this.architecture,
    required this.os,
    required this.size,
    required this.created,
    required this.env,
    required this.exposedPorts,
  });

  factory ImageDetail.fromJson(Map<String, dynamic> json) {
    final config = (json['Config'] as Map<String, dynamic>?) ?? const {};
    final exposed = (config['ExposedPorts'] as Map<String, dynamic>?)?.keys.toList() ?? const <String>[];
    return ImageDetail(
      id: json['Id'] as String? ?? '',
      repoTags: (json['RepoTags'] as List?)?.cast<String>() ?? const [],
      architecture: json['Architecture'] as String? ?? '',
      os: json['Os'] as String? ?? '',
      size: (json['Size'] as num?)?.toInt() ?? 0,
      created: json['Created'] as String? ?? '',
      env: (config['Env'] as List?)?.cast<String>() ?? const [],
      exposedPorts: exposed,
    );
  }
}
