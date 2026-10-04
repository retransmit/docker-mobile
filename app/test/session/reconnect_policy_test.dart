import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/session/reconnect_policy.dart';

void main() {
  test('delays double from 1 s and cap at 30 s without jitter', () {
    final p = ReconnectPolicy(jitter: 0);
    expect(p.delay(1), const Duration(seconds: 1));
    expect(p.delay(2), const Duration(seconds: 2));
    expect(p.delay(3), const Duration(seconds: 4));
    expect(p.delay(5), const Duration(seconds: 16));
    expect(p.delay(6), const Duration(seconds: 30));
    expect(p.delay(60), const Duration(seconds: 30));
  });

  test('attempt below 1 is treated as the first attempt', () {
    expect(ReconnectPolicy(jitter: 0).delay(0), const Duration(seconds: 1));
  });

  test('jitter stays within plus or minus 20 percent', () {
    final p = ReconnectPolicy(random: Random(42));
    for (var i = 0; i < 200; i++) {
      final d = p.delay(3).inMicroseconds;
      expect(d, inInclusiveRange(3200000, 4800000));
    }
  });

  test('defaults to five attempts', () {
    expect(ReconnectPolicy().maxAttempts, 5);
  });
}
