import '../stdcopy.dart';

/// One rendered log line with its source stream and optional timestamp.
class LogLine {
  final LogStream source;
  final String text;
  final DateTime? timestamp;

  /// The daemon's RFC3339Nano timestamp string, kept verbatim so lines can be
  /// compared exactly; convert it with [rfc3339ToUnixNanos] before passing it
  /// back as a since cursor (the Engine only accepts `<seconds>.<nanos>`).
  final String? rawTimestamp;

  const LogLine({required this.source, required this.text, this.timestamp, this.rawTimestamp});
}
