import '../stdcopy.dart';

/// One rendered log line with its source stream and optional timestamp.
class LogLine {
  final LogStream source;
  final String text;
  final DateTime? timestamp;

  const LogLine({required this.source, required this.text, this.timestamp});
}
