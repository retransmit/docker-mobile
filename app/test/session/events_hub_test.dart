import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/api/models/docker_event.dart';
import 'package:docker_mobile/src/session/events_hub.dart';

import '../support/fake_session.dart';

DockerEvent ev(String type, {String action = 'start', String id = 'c1', int? t}) =>
    DockerEvent(type: type, action: action, target: id, actorId: id, timeNano: t);

class _Hub {
  final opens = <String?>[];
  final controllers = <StreamController<DockerEvent>>[];
  final seen = <DockerEvent>[];
  final lost = <DockerError>[];
  final inv = RecordingInvalidator();
  late final EventsHub hub = EventsHub(
    open: (since) {
      opens.add(since);
      final c = StreamController<DockerEvent>();
      controllers.add(c);
      return c.stream;
    },
    onEvent: seen.add,
    invalidator: inv,
    onLost: lost.add,
  );
  StreamController<DockerEvent> get last => controllers.last;
}

void main() {
  test('forwards every event and debounces list, detail and dashboard refreshes', () {
    fakeAsync((async) {
      final h = _Hub()..hub.start();
      for (var i = 0; i < 10; i++) {
        h.last.add(ev('container'));
        async.elapse(const Duration(milliseconds: 10));
      }
      expect(h.seen, hasLength(10));
      async.elapse(const Duration(milliseconds: 489));
      expect(h.inv.calls, isEmpty);
      async.elapse(const Duration(milliseconds: 20));
      expect(h.inv.calls, unorderedEquals(['list:container', 'detail:container:c1']));
      async.elapse(const Duration(seconds: 2));
      expect(h.inv.calls.where((c) => c == 'dashboard'), hasLength(1));
    });
  });

  test('categories map to the right invalidations', () {
    fakeAsync((async) {
      final h = _Hub()..hub.start();
      h.last
        ..add(ev('image', id: 'sha256:abc'))
        ..add(ev('network', id: 'n1'))
        ..add(ev('volume', id: 'v1'))
        ..add(ev('plugin', id: 'p1'));
      async.elapse(const Duration(seconds: 3));
      expect(
        h.inv.calls,
        unorderedEquals(['list:image', 'detail:image:sha256:abc', 'list:network', 'list:volume', 'dashboard']),
      );
      expect(h.seen, hasLength(4));
    });
  });

  test('health-check exec events reach the feed but refresh nothing', () {
    fakeAsync((async) {
      final h = _Hub()..hub.start();
      h.last
        ..add(ev('container', action: 'exec_create: /bin/sh -c curl -f localhost'))
        ..add(ev('container', action: 'exec_start: /bin/sh -c curl -f localhost'))
        ..add(ev('container', action: 'exec_die'));
      async.elapse(const Duration(seconds: 3));
      expect(h.seen, hasLength(3));
      expect(h.inv.calls, isEmpty);
    });
  });

  test('tracks the cursor; resume asks for since and drops events at or before it', () {
    fakeAsync((async) {
      final h = _Hub()..hub.start();
      expect(h.opens, [null]);
      h.last
        ..add(ev('container', t: 100))
        ..add(ev('container', t: 200));
      async.flushMicrotasks();
      expect(h.hub.cursorNano, 200);
      h.hub.pause();
      async.flushMicrotasks();
      expect(h.last.hasListener, isFalse);
      expect(h.lost, isEmpty);
      h.hub.resume();
      expect(h.opens.last, '0.000000200');
      h.last
        ..add(ev('container', t: 200))
        ..add(ev('container', t: 300));
      async.flushMicrotasks();
      expect(h.seen.map((e) => e.timeNano), [100, 200, 300]);
      expect(h.hub.cursorNano, 300);
    });
  });

  test('start resets the cursor', () {
    fakeAsync((async) {
      final h = _Hub()..hub.start();
      h.last.add(ev('container', t: 500));
      async.flushMicrotasks();
      h.hub.stop();
      h.hub.start();
      expect(h.opens.last, isNull);
      expect(h.hub.cursorNano, isNull);
    });
  });

  test('a stream error reports liveness lost once, as a network error', () {
    fakeAsync((async) {
      final h = _Hub()..hub.start();
      h.last.addError(const SocketException('reset'));
      async.flushMicrotasks();
      expect(h.lost, hasLength(1));
      expect(h.lost.single.kind, DockerErrorKind.network);
      expect(h.hub.active, isFalse);
    });
  });

  test('a clean end of the stream reports liveness lost', () {
    fakeAsync((async) {
      final h = _Hub()..hub.start();
      h.last.close();
      async.flushMicrotasks();
      expect(h.lost, hasLength(1));
      expect(h.lost.single.retryable, isTrue);
    });
  });

  test('pausing never reports a loss, even if the old stream later errors', () {
    fakeAsync((async) {
      final h = _Hub()..hub.start();
      final old = h.last;
      h.hub.pause();
      old.addError(const SocketException('late'));
      async.flushMicrotasks();
      expect(h.lost, isEmpty);
    });
  });

  test('stop cancels pending refreshes', () {
    fakeAsync((async) {
      final h = _Hub()..hub.start();
      h.last.add(ev('container'));
      async.flushMicrotasks();
      h.hub.stop();
      expect(async.pendingTimers, isEmpty);
      async.elapse(const Duration(seconds: 3));
      expect(h.inv.calls, isEmpty);
    });
  });
}
