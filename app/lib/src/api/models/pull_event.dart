/// One JSON line from `POST /images/create` progress.
class PullEvent {
  final String status;
  final String? id;
  final int? current;
  final int? total;
  final String? error;

  const PullEvent({this.status = '', this.id, this.current, this.total, this.error});

  factory PullEvent.fromJson(Map<String, dynamic> json) {
    final detail = json['progressDetail'] as Map<String, dynamic>?;
    return PullEvent(
      status: json['status'] as String? ?? '',
      id: json['id'] as String?,
      current: (detail?['current'] as num?)?.toInt(),
      total: (detail?['total'] as num?)?.toInt(),
      error: json['error'] as String?,
    );
  }
}
