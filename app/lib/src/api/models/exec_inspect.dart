/// Subset of `GET /exec/{id}/json`.
class ExecInspect {
  final bool running;
  final int? exitCode;
  const ExecInspect({required this.running, this.exitCode});

  factory ExecInspect.fromJson(Map<String, dynamic> json) => ExecInspect(
        running: json['Running'] as bool? ?? false,
        exitCode: json['ExitCode'] as int?,
      );
}
