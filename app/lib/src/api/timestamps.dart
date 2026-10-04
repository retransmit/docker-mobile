/// Docker's `since` query format for logs and events: `<seconds>.<nanos>`.
String formatUnixNanos(int timeNano) {
  final secs = timeNano ~/ 1000000000;
  final nanos = timeNano % 1000000000;
  return '$secs.${nanos.toString().padLeft(9, '0')}';
}

/// Converts an RFC3339(Nano) timestamp as emitted by `--timestamps` logs to
/// the `since` format, keeping all nine fractional digits. Null if unparsable.
String? rfc3339ToUnixNanos(String ts) {
  final dt = DateTime.tryParse(ts);
  if (dt == null) return null;
  final secs = dt.toUtc().millisecondsSinceEpoch ~/ 1000;
  var frac = '';
  final dot = ts.indexOf('.');
  if (dot != -1) {
    final end = ts.indexOf(RegExp(r'[Zz+\-]'), dot);
    frac = ts.substring(dot + 1, end == -1 ? ts.length : end);
  }
  frac = frac.length > 9 ? frac.substring(0, 9) : frac.padRight(9, '0');
  return '$secs.$frac';
}

/// An RFC3339(Nano) timestamp as epoch nanoseconds (fits in 64 bits until
/// the year 2262), keeping all nine fractional digits. Null if unparsable.
int? rfc3339ToEpochNanos(String ts) {
  final s = rfc3339ToUnixNanos(ts);
  if (s == null) return null;
  final dot = s.indexOf('.');
  final secs = int.tryParse(s.substring(0, dot));
  final nanos = int.tryParse(s.substring(dot + 1));
  if (secs == null || nanos == null) return null;
  return secs * 1000000000 + nanos;
}
