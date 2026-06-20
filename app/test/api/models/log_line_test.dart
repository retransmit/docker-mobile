import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';
import 'package:docker_mobile/src/api/models/log_line.dart';

void main() {
  test('holds source, text, and optional timestamp', () {
    final ts = DateTime.utc(2026, 1, 2, 3, 4, 5);
    final l = LogLine(source: LogStream.stderr, text: 'boom', timestamp: ts);
    expect(l.source, LogStream.stderr);
    expect(l.text, 'boom');
    expect(l.timestamp, ts);
  });

  test('timestamp is optional', () {
    final l = LogLine(source: LogStream.stdout, text: 'ok');
    expect(l.timestamp, isNull);
  });
}
