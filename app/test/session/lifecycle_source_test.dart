import 'dart:async';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/session/lifecycle_source.dart';

import '../support/fake_session.dart';

void main() {
  testWidgets('AppLifecycleSource reports app lifecycle changes while listened to', (tester) async {
    final source = AppLifecycleSource();
    final seen = <AppLifecycleState>[];
    final sub = source.changes.listen(seen.add);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(seen, contains(AppLifecycleState.paused));
    unawaited(sub.cancel()); // awaiting a cancel inside testWidgets hangs teardown
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  });

  test('creating an AppLifecycleSource does not touch the binding', () {
    // Plain test(): no binding is initialised. Construction must not throw.
    expect(AppLifecycleSource.new, returnsNormally);
  });

  test('ManualLifecycleSource delivers synchronously', () {
    final m = ManualLifecycleSource();
    final seen = <AppLifecycleState>[];
    m.changes.listen(seen.add);
    m.emit(AppLifecycleState.paused);
    expect(seen, [AppLifecycleState.paused]);
  });
}
