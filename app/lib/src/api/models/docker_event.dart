class DockerEvent {
  final String type;
  final String action;
  final String target;
  final String actorId;
  final DateTime? time;
  final int? timeNano;

  const DockerEvent({
    required this.type,
    required this.action,
    required this.target,
    this.actorId = '',
    this.time,
    this.timeNano,
  });

  factory DockerEvent.fromJson(Map<String, dynamic> json) {
    final actor = (json['Actor'] as Map?) ?? const {};
    final attrs = (actor['Attributes'] as Map?) ?? const {};
    final id = actor['ID'] as String? ?? '';
    final name = attrs['name'] as String?;
    final target = (name != null && name.isNotEmpty) ? name : (id.length > 12 ? id.substring(0, 12) : id);
    final timeNano = (json['timeNano'] as num?)?.toInt();
    final timeSec = (json['time'] as num?)?.toInt();
    final time = timeNano != null
        ? DateTime.fromMicrosecondsSinceEpoch(timeNano ~/ 1000)
        : (timeSec != null ? DateTime.fromMillisecondsSinceEpoch(timeSec * 1000) : null);
    return DockerEvent(
      type: json['Type'] as String? ?? '',
      action: json['Action'] as String? ?? '',
      target: target,
      actorId: id,
      time: time,
      timeNano: timeNano,
    );
  }
}
