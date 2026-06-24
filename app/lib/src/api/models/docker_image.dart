/// A Docker image as returned by `GET /images/json`.
class DockerImage {
  final String id;
  final List<String> repoTags;
  final int size;
  final int created;

  const DockerImage({required this.id, required this.repoTags, required this.size, required this.created});

  factory DockerImage.fromJson(Map<String, dynamic> json) => DockerImage(
        id: json['Id'] as String? ?? '',
        repoTags: (json['RepoTags'] as List?)?.cast<String>() ?? const [],
        size: (json['Size'] as num?)?.toInt() ?? 0,
        created: (json['Created'] as num?)?.toInt() ?? 0,
      );
}
