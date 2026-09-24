import '../stdcopy.dart';

/// One rendered log line with its source stream and optional timestamp.
/// [rawTimestamp] is the daemon's RFC3339Nano string, kept verbatim so a
/// resumed stream can pass it back as `since` without precision loss.
class LogLine {
  final LogStream source;
  final String text;
  final DateTime? timestamp;
  final String? rawTimestamp;

  const LogLine({required this.source, required this.text, this.timestamp, this.rawTimestamp});
}
