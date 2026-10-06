import 'dart:math';

/// Exponential backoff with jitter: delay(n) = min(base x 2^(n-1), cap),
/// scaled by a random factor in [1 - jitter, 1 + jitter]. Shared by the
/// session reconnect loop and the stream supervisors.
class ReconnectPolicy {
  final Duration base;
  final Duration cap;
  final double jitter;

  /// Attempts before giving up and reporting failure.
  final int maxAttempts;
  final Random _random;

  ReconnectPolicy({
    this.base = const Duration(seconds: 1),
    this.cap = const Duration(seconds: 30),
    this.jitter = 0.2,
    this.maxAttempts = 5,
    Random? random,
  }) : _random = random ?? Random();

  /// The wait before attempt [attempt] (1-based; values below 1 count as 1).
  Duration delay(int attempt) {
    final n = attempt < 1 ? 1 : attempt;
    final exponent = min(n - 1, 30); // keep the shift far from overflow
    final raw = base.inMicroseconds * (1 << exponent);
    final capped = min(raw, cap.inMicroseconds);
    final factor = 1 + jitter * (2 * _random.nextDouble() - 1);
    return Duration(microseconds: (capped * factor).round());
  }
}
