import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:docker_mobile/src/session/lifecycle_source.dart';
import 'package:docker_mobile/src/session/reconnect_policy.dart';

/// A lifecycle source the test drives; delivery is synchronous.
class ManualLifecycleSource implements LifecycleSource {
  final _controller = StreamController<AppLifecycleState>.broadcast(sync: true);

  @override
  Stream<AppLifecycleState> get changes => _controller.stream;

  void emit(AppLifecycleState state) => _controller.add(state);
}

/// A policy with zero delays, for tests that do not care about timing.
ReconnectPolicy immediatePolicy({int maxAttempts = 5}) =>
    ReconnectPolicy(base: Duration.zero, cap: Duration.zero, jitter: 0, maxAttempts: maxAttempts);
