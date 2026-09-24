import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/timestamps.dart';

void main() {
  test('formatUnixNanos zero-pads the fraction to 9 digits', () {
    expect(formatUnixNanos(1700000000000000123), '1700000000.000000123');
    expect(formatUnixNanos(1700000000123456789), '1700000000.123456789');
    expect(formatUnixNanos(1700000000000000000), '1700000000.000000000');
  });

  test('rfc3339ToUnixNanos keeps full nanosecond precision', () {
    final secs = DateTime.utc(2026, 9, 24, 10, 0, 0).millisecondsSinceEpoch ~/ 1000;
    expect(rfc3339ToUnixNanos('2026-09-24T10:00:00.123456789Z'), '$secs.123456789');
    expect(rfc3339ToUnixNanos('2026-09-24T10:00:00.5Z'), '$secs.500000000');
    expect(rfc3339ToUnixNanos('2026-09-24T10:00:00Z'), '$secs.000000000');
  });

  test('rfc3339ToUnixNanos handles offsets and rejects garbage', () {
    final secs = DateTime.utc(2026, 9, 24, 8, 0, 0).millisecondsSinceEpoch ~/ 1000;
    expect(rfc3339ToUnixNanos('2026-09-24T10:00:00.25+02:00'), '$secs.250000000');
    expect(rfc3339ToUnixNanos('not a time'), isNull);
    expect(rfc3339ToUnixNanos(''), isNull);
  });
}
