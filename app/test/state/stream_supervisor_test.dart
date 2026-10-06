import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/session/reconnect_policy.dart';
import 'package:docker_mobile/src/state/stream_supervisor.dart';

const _net = DockerError(DockerErrorKind.network, 'down');

class _Opens {
  final controllers = <StreamController<int>>[];
  int cancelled = 0;
  Object? throwNext;

  Stream<int> open() {
    final t = throwNext;
    if (t != null) {
      throwNext = null;
      throw t;
    }
    final c = StreamController<int>(onCancel: () => cancelled++);
    controllers.add(c);
    return c.stream;
  }
}

class _Harness {
  final opens = _Opens();
  final data = <int>[];
  final statuses = <(SupervisorStatus, DockerError?)>[];
  late final StreamSupervisor<int> sup;

  _Harness({bool retryOnDone = false, int maxAttempts = 5}) {
    sup = StreamSupervisor<int>(
      open: opens.open,
      onData: data.add,
      onStatus: (s, e) => statuses.add((s, e)),
      policy: ReconnectPolicy(jitter: 0, maxAttempts: maxAttempts),
      retryOnDone: retryOnDone,
    );
  }

  SupervisorStatus get last => statuses.last.$1;
}

void main() {
  test('forwards data while streaming', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.add(1);
      async.flushMicrotasks();
      expect(h.data, [1]);
      expect(h.last, SupervisorStatus.streaming);
    });
  });

  test('a retryable error reopens after the backoff delay', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      expect(h.last, SupervisorStatus.retrying);
      expect(h.statuses.last.$2, same(_net));
      async.elapse(const Duration(milliseconds: 999));
      expect(h.opens.controllers, hasLength(1));
      async.elapse(const Duration(milliseconds: 2));
      expect(h.opens.controllers, hasLength(2));
      expect(h.last, SupervisorStatus.streaming);
    });
  });

  test('gives up after maxAttempts retries', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      for (var i = 1; i <= 5; i++) {
        h.opens.controllers.last.addError(_net);
        async.flushMicrotasks();
        expect(h.last, SupervisorStatus.retrying);
        async.elapse(Duration(seconds: 1 << (i - 1)));
      }
      expect(h.opens.controllers, hasLength(6));
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      expect(h.last, SupervisorStatus.failed);
      expect(h.statuses.last.$2, same(_net));
      async.elapse(const Duration(minutes: 5));
      expect(h.opens.controllers, hasLength(6));
    });
  });

  test('a non-retryable error fails at once', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.addError(DockerError.fromResponse(404, '{"message":"No such container"}'));
      async.flushMicrotasks();
      expect(h.last, SupervisorStatus.failed);
      expect(h.statuses.last.$2!.message, 'No such container');
      async.elapse(const Duration(minutes: 1));
      expect(h.opens.controllers, hasLength(1));
    });
  });

  test('data resets the attempt count', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      h.opens.controllers.last.add(7);
      async.flushMicrotasks();
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1)); // 1 s again, not 2 s
      expect(h.opens.controllers, hasLength(3));
    });
  });

  test('pause cancels the stream and resume reopens with a fresh open()', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      async.flushMicrotasks();
      h.sup.pause();
      async.flushMicrotasks();
      expect(h.opens.cancelled, 1);
      expect(h.last, SupervisorStatus.paused);
      h.sup.resume();
      expect(h.opens.controllers, hasLength(2));
      expect(h.last, SupervisorStatus.streaming);
    });
  });

  test('pause while retrying cancels the timer; resume reopens at once', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      h.sup.pause();
      async.elapse(const Duration(seconds: 10));
      expect(h.opens.controllers, hasLength(1));
      h.sup.resume();
      expect(h.opens.controllers, hasLength(2));
    });
  });

  test('pause and resume do nothing once failed or done', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.close();
      async.flushMicrotasks();
      expect(h.last, SupervisorStatus.done);
      h.sup.pause();
      h.sup.resume();
      expect(h.last, SupervisorStatus.done);
      expect(h.opens.controllers, hasLength(1));
    });
  });

  test('done stays done', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.close();
      async.flushMicrotasks();
      expect(h.last, SupervisorStatus.done);
      async.elapse(const Duration(minutes: 1));
      expect(h.opens.controllers, hasLength(1));
    });
  });

  test('retryOnDone treats a clean end as a retryable loss', () {
    fakeAsync((async) {
      final h = _Harness(retryOnDone: true)..sup.start();
      h.opens.controllers.last.close();
      async.flushMicrotasks();
      expect(h.last, SupervisorStatus.retrying);
      async.elapse(const Duration(seconds: 1));
      expect(h.opens.controllers, hasLength(2));
    });
  });

  test('retry() reopens from failed with a fresh attempt count', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.addError(DockerError.fromResponse(404, ''));
      async.flushMicrotasks();
      expect(h.last, SupervisorStatus.failed);
      h.sup.retry();
      expect(h.opens.controllers, hasLength(2));
      expect(h.last, SupervisorStatus.streaming);
    });
  });

  test('a synchronous throw from open() is handled like a stream error', () {
    fakeAsync((async) {
      final h = _Harness();
      h.opens.throwNext = const SocketException('refused');
      h.sup.start();
      expect(h.last, SupervisorStatus.retrying);
      async.elapse(const Duration(seconds: 1));
      expect(h.opens.controllers, hasLength(1));
      expect(h.last, SupervisorStatus.streaming);
    });
  });

  test('dispose cancels the stream and any pending retry and goes quiet', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      final count = h.statuses.length;
      h.sup.dispose();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(minutes: 1));
      expect(h.statuses.length, count);
      expect(h.opens.controllers, hasLength(1));
    });
  });

  test('a stream open for the policy cap without error counts as recovered', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(h.opens.controllers, hasLength(2));
      async.elapse(const Duration(seconds: 30)); // quiet, no data
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      expect(h.last, SupervisorStatus.retrying);
      async.elapse(const Duration(seconds: 1)); // 1 s again, not 2 s
      expect(h.opens.controllers, hasLength(3));
    });
  });

  test('an error within the policy cap keeps backing off', () {
    fakeAsync((async) {
      final h = _Harness()..sup.start();
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(h.opens.controllers, hasLength(2));
      async.elapse(const Duration(seconds: 29));
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 1));
      expect(h.opens.controllers, hasLength(2)); // 2 s now, not 1 s
      async.elapse(const Duration(seconds: 1));
      expect(h.opens.controllers, hasLength(3));
      // The errored stream's stability timer must not reset the count while
      // the retry was pending: the next delay is 4 s.
      h.opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 3));
      expect(h.opens.controllers, hasLength(3));
      async.elapse(const Duration(seconds: 1));
      expect(h.opens.controllers, hasLength(4));
    });
  });

  test('pause from onStatus(retrying) stops the retry timer', () {
    fakeAsync((async) {
      final opens = _Opens();
      late final StreamSupervisor<int> sup;
      sup = StreamSupervisor<int>(
        open: opens.open,
        onData: (_) {},
        onStatus: (s, e) {
          if (s == SupervisorStatus.retrying) sup.pause();
        },
        policy: ReconnectPolicy(jitter: 0),
      );
      sup.start();
      opens.controllers.last.addError(_net);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));
      expect(opens.controllers, hasLength(1));
      expect(sup.status, SupervisorStatus.paused);
    });
  });

  test('dispose from onStatus(streaming) never listens to the opened stream', () {
    fakeAsync((async) {
      final opens = _Opens();
      late final StreamSupervisor<int> sup;
      sup = StreamSupervisor<int>(
        open: opens.open,
        onData: (_) {},
        onStatus: (s, e) {
          if (s == SupervisorStatus.streaming) sup.dispose();
        },
        policy: ReconnectPolicy(jitter: 0),
      );
      sup.start();
      async.flushMicrotasks();
      expect(opens.controllers, hasLength(1));
      expect(opens.controllers.last.hasListener, isFalse);
      expect(async.pendingTimers, isEmpty);
    });
  });
}
