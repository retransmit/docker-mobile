import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/api/models/docker_event.dart';
import 'package:docker_mobile/src/session/docker_session.dart';
import 'package:docker_mobile/src/session/reconnect_policy.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/session/transport_factory.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';

import '../support/fake_session.dart';
import '../support/fake_transport.dart';

const agentA = ConnectionProfile(id: 'a', name: 'A', kind: ConnectionKind.agent,
    agent: AgentCredentials(baseUri: 'http://a:1', token: 't'));
const agentB = ConnectionProfile(id: 'b', name: 'B', kind: ConnectionKind.agent,
    agent: AgentCredentials(baseUri: 'http://b:1', token: 't'));
ConnectionProfile sshProfile({String? pin}) => ConnectionProfile(id: 's', name: 'S', kind: ConnectionKind.ssh,
    ssh: SshCredentials(host: 'h', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p', pinnedHostKey: pin));

const _down = DockerError(DockerErrorKind.network, 'down');

/// Fails the full refresh; everything else is recorded.
class _ThrowingInvalidator extends RecordingInvalidator {
  @override
  void all() => throw StateError('refresh failed');
}

/// A daemon whose `/_ping` answers only once [answer] is completed.
class _HeldPing extends FakeTransport {
  _HeldPing() {
    onGet('/_ping', (_) => http.Response('OK', 200));
    onGet('/version', (_) => http.Response(jsonEncode({'Version': '27.0', 'ApiVersion': '1.46'}), 200));
  }

  final answer = Completer<void>();

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path == '/_ping') await answer.future;
    return super.get(path, query: query);
  }
}

/// A daemon whose `/_ping` answers the probe at once. Every later ping waits
/// in [pings] until the test completes it, or fails it with an error.
class _PingsOnHold extends FakeTransport {
  _PingsOnHold() {
    onGet('/_ping', (_) => http.Response('OK', 200));
    onGet('/version', (_) => http.Response(jsonEncode({'Version': '27.0', 'ApiVersion': '1.46'}), 200));
    onStream(RegExp(r'/events$'), (_) {
      final events = StreamController<List<int>>();
      eventStreams.add(events);
      return events.stream;
    });
  }

  final pings = <Completer<void>>[];

  /// Every events stream opened, oldest first.
  final eventStreams = <StreamController<List<int>>>[];
  bool _probed = false;

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path == '/_ping') {
      if (_probed) {
        final held = Completer<void>();
        pings.add(held);
        await held.future;
      }
      _probed = true;
    }
    return super.get(path, query: query);
  }
}

/// A daemon that answers the probe but ends its events stream as soon as it
/// is opened, like a proxy that lets ping and version through and cannot stream.
FakeDaemon _noEventsDaemon() =>
    FakeDaemon()..transport.onStream(RegExp(r'/events$'), (_) => const Stream<List<int>>.empty());

/// A profile store whose `update` finishes only once [written] is completed.
class _HeldUpdateStore extends InMemoryProfileStore {
  final written = Completer<void>();

  @override
  Future<void> update(ConnectionProfile profile) async {
    await written.future;
    return super.update(profile);
  }
}

class _Harness {
  _Harness(List<Object> builds, {ReconnectPolicy? policy, RecordingInvalidator? invalidator, InMemoryProfileStore? store})
      : factory = FakeTransportFactory(builds),
        lifecycle = ManualLifecycleSource(),
        invalidator = invalidator ?? RecordingInvalidator(),
        store = store ?? InMemoryProfileStore() {
    session = DockerSession(
      transportFactory: factory,
      policy: policy ?? ReconnectPolicy(jitter: 0),
      lifecycle: lifecycle,
      invalidator: this.invalidator,
      profileStore: this.store,
      onEvent: events.add,
      onNewSession: () => newSessions++,
      onProfilesChanged: () => profileChanges++,
    );
  }

  final FakeTransportFactory factory;
  final ManualLifecycleSource lifecycle;
  final RecordingInvalidator invalidator;
  final InMemoryProfileStore store;
  late final DockerSession session;
  final events = <DockerEvent>[];
  int newSessions = 0;
  int profileChanges = 0;

  SessionState get s => session.state;
}

/// Connects [h] to [profile] and loses the event stream of [d].
// ignore: library_private_types_in_public_api
void connectThenLose(FakeAsync async, _Harness h, FakeDaemon d, {ConnectionProfile profile = agentA}) {
  h.session.connect(profile);
  async.flushMicrotasks();
  d.events.addError(const SocketException('reset'));
  async.flushMicrotasks();
}

void main() {
  group('connect', () {
    test('pings, negotiates, opens the events stream and goes live', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final h = _Harness([d.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.apiVersion, '1.45');
        expect(h.s.daemon!.apiVersion, '1.46');
        expect(h.s.transport, same(d.transport));
        expect(h.s.sessionId, 1);
        expect(h.s.warning, isNull);
        expect(h.newSessions, 1);
        expect(
          d.transport.calls.map((c) => '${c.method} ${c.path}'),
          containsAllInOrder(['GET /_ping', 'GET /version', 'STREAM /v1.45/events']),
        );
        expect(d.activeEventStreams, 1);
      });
    });

    test('a failed probe leaves the session disconnected with the error and closes the transport', () {
      fakeAsync((async) {
        final d = FakeDaemon(pingStatus: 401);
        final h = _Harness([d.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.disconnected);
        expect(h.s.error!.kind, DockerErrorKind.unauthorized);
        expect(h.s.profile!.id, 'a');
        expect(h.s.transport, isNull);
        expect(d.transport.closed, isTrue);
        expect(d.eventOpens, isEmpty);
      });
    });

    test('a failed build leaves the session disconnected with the error', () {
      fakeAsync((async) {
        final h = _Harness([const DockerError(DockerErrorKind.network, 'refused')]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.disconnected);
        expect(h.s.error!.message, 'refused');
      });
    });

    test('a host-key mismatch is rethrown with no error left in state', () {
      fakeAsync((async) {
        final h = _Harness([const HostKeyMismatchException('FP-NEW')]);
        Object? thrown;
        h.session.connect(sshProfile(pin: 'FP-OLD')).then((_) {}, onError: (Object e) {
          thrown = e;
        });
        async.flushMicrotasks();
        expect(thrown, isA<HostKeyMismatchException>());
        expect(h.s.status, SessionStatus.disconnected);
        expect(h.s.error, isNull);
      });
    });

    test('SSH first use persists the presented host key', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final h = _Harness([BuiltTransport(d.transport, presentedHostKey: 'FP')]);
        h.store.add(sshProfile());
        async.flushMicrotasks();
        h.session.connect(sshProfile());
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.profile!.ssh!.pinnedHostKey, 'FP');
        h.store.list().then((ps) => expect(ps.single.ssh!.pinnedHostKey, 'FP'));
        async.flushMicrotasks();
        expect(h.profileChanges, 1);
      });
    });

    test('trusting a changed key connects with the override and re-pins', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final h = _Harness([BuiltTransport(d.transport, presentedHostKey: 'FP-NEW')]);
        h.store.add(sshProfile(pin: 'FP-OLD'));
        async.flushMicrotasks();
        h.session.connect(sshProfile(pin: 'FP-OLD'), pinOverride: 'FP-NEW');
        async.flushMicrotasks();
        expect(h.factory.pinOverrides, ['FP-NEW']);
        h.store.list().then((ps) => expect(ps.single.ssh!.pinnedHostKey, 'FP-NEW'));
        async.flushMicrotasks();
        expect(h.profileChanges, 1);
      });
    });

    test('an old daemon connects with a one-time warning that can be acknowledged', () {
      fakeAsync((async) {
        final h = _Harness([FakeDaemon(apiVersion: '1.40').transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.apiVersion, '1.40');
        expect(h.s.warning, contains('1.40'));
        h.session.acknowledgeWarning();
        expect(h.s.warning, isNull);
      });
    });

    test('a daemon reporting no API version gets no warning and the client version', () {
      fakeAsync((async) {
        final h = _Harness([FakeDaemon(apiVersion: '').transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        expect(h.s.warning, isNull);
        expect(h.s.apiVersion, '1.45');
      });
    });

    test('a second connect while connecting is ignored', () {
      fakeAsync((async) {
        final pending = Completer<BuiltTransport>();
        final h = _Harness([pending.future]);
        h.session.connect(agentA);
        h.session.connect(agentA);
        async.flushMicrotasks();
        expect(h.factory.builds, 1);
      });
    });

    test('a host-key mismatch from a superseded connect is swallowed', () {
      fakeAsync((async) {
        final pending = Completer<BuiltTransport>();
        final h = _Harness([pending.future]);
        Object? error;
        var completed = false;
        h.session.connect(sshProfile(pin: 'FP-OLD')).then((_) {
          completed = true;
        }, onError: (Object e) {
          error = e;
        });
        async.flushMicrotasks();
        h.session.disconnect();
        async.flushMicrotasks();
        pending.completeError(const HostKeyMismatchException('FP'));
        async.flushMicrotasks();
        expect(error, isNull);
        expect(completed, isTrue);
        expect(h.s.status, SessionStatus.disconnected);
      });
    });

    test('connecting to another profile closes the previous transport and starts a new session', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final d2 = FakeDaemon();
        final h = _Harness([d1.transport, d2.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        h.session.connect(agentB);
        async.flushMicrotasks();
        expect(d1.transport.closed, isTrue);
        expect(d1.activeEventStreams, 0);
        expect(h.s.transport, same(d2.transport));
        expect(h.s.profile!.id, 'b');
        expect(h.s.sessionId, 2);
        expect(h.newSessions, 2);
      });
    });

    group('connect reports whether this attempt connected:', () {
      /// Starts a connect; the returned reader gives what it reported, or null while it is in flight.
      bool? Function() report(_Harness h, ConnectionProfile profile) {
        bool? result;
        h.session.connect(profile).then((v) => result = v);
        return () => result;
      }

      test('true for a good connect', () {
        fakeAsync((async) {
          final h = _Harness([FakeDaemon().transport]);
          final result = report(h, agentA);
          async.flushMicrotasks();
          expect(result(), isTrue);
          expect(h.s.status, SessionStatus.connected);
        });
      });

      test('false for a refused one, with the error in state', () {
        fakeAsync((async) {
          final h = _Harness([const DockerError(DockerErrorKind.network, 'refused')]);
          final result = report(h, agentA);
          async.flushMicrotasks();
          expect(result(), isFalse);
          expect(h.s.status, SessionStatus.disconnected);
          expect(h.s.error!.message, 'refused');
        });
      });

      test('false for a daemon that fails the probe', () {
        fakeAsync((async) {
          final h = _Harness([FakeDaemon(pingStatus: 401).transport]);
          final result = report(h, agentA);
          async.flushMicrotasks();
          expect(result(), isFalse);
          expect(h.s.error!.kind, DockerErrorKind.unauthorized);
        });
      });

      test('false for a second call while the first is in flight, which still reports true', () {
        fakeAsync((async) {
          final pending = Completer<BuiltTransport>();
          final h = _Harness([pending.future]);
          final first = report(h, agentA);
          final second = report(h, agentB);
          async.flushMicrotasks();
          expect(second(), isFalse); // ignored at once
          expect(first(), isNull); // still in flight
          pending.complete(BuiltTransport(FakeDaemon().transport));
          async.flushMicrotasks();
          expect(first(), isTrue);
          expect(h.s.profile!.id, 'a');
          expect(h.factory.builds, 1);
        });
      });

      final lateHandshakes = <String, void Function(Completer<BuiltTransport>, FakeDaemon)>{
        'answers': (pending, d) => pending.complete(BuiltTransport(d.transport)),
        'fails': (pending, d) => pending.completeError(const DockerError(DockerErrorKind.timeout, 'timed out')),
        'reports a changed host key': (pending, d) => pending.completeError(const HostKeyMismatchException('FP')),
      };
      for (final MapEntry(key: outcome, value: finish) in lateHandshakes.entries) {
        test('false for an attempt cancelled by disconnect() whose handshake $outcome later', () {
          fakeAsync((async) {
            final pending = Completer<BuiltTransport>();
            final d = FakeDaemon();
            final h = _Harness([pending.future]);
            bool? result;
            Object? error;
            h.session.connect(sshProfile(pin: 'FP-OLD')).then((v) {
              result = v;
            }, onError: (Object e) {
              error = e;
            });
            async.flushMicrotasks();
            h.session.disconnect();
            async.flushMicrotasks();
            expect(result, isNull); // its handshake is still out

            finish(pending, d);
            async.flushMicrotasks();
            expect(result, isFalse);
            expect(error, isNull);
            expect(h.s.status, SessionStatus.disconnected);
            expect(h.s.error, isNull);
            if (outcome == 'answers') {
              expect(d.transport.closed, isTrue);
              expect(d.transport.calls, isEmpty);
            }
          });
        });
      }

      test('false for an attempt cancelled while its probe is out; its transport is closed', () {
        fakeAsync((async) {
          final t = _HeldPing();
          final h = _Harness([t]);
          final result = report(h, agentA);
          async.flushMicrotasks();
          expect(h.s.status, SessionStatus.connecting);
          h.session.disconnect();
          async.flushMicrotasks();
          t.answer.complete();
          async.flushMicrotasks();
          expect(result(), isFalse);
          expect(h.s.status, SessionStatus.disconnected);
          expect(t.closed, isTrue);
        });
      });

      test('false for an attempt cancelled while its host key is being saved; its transport is closed', () {
        fakeAsync((async) {
          final d = FakeDaemon();
          final store = _HeldUpdateStore();
          final h = _Harness([BuiltTransport(d.transport, presentedHostKey: 'FP')], store: store);
          store.add(sshProfile());
          async.flushMicrotasks();
          final result = report(h, sshProfile());
          async.flushMicrotasks();
          expect(h.s.status, SessionStatus.connecting); // the probe is done, the pin write is out
          h.session.disconnect();
          async.flushMicrotasks();
          store.written.complete();
          async.flushMicrotasks();
          expect(result(), isFalse);
          expect(h.s.status, SessionStatus.disconnected);
          expect(d.transport.closed, isTrue);
          // The write went through all the same: the pin is stored, so the list must hear of it,
          // or the next tap would connect with the unpinned copy.
          h.store.list().then((ps) => expect(ps.single.ssh!.pinnedHostKey, 'FP'));
          async.flushMicrotasks();
          expect(h.profileChanges, 1);
        });
      });
    });

    test('a host key saved after the session was disposed is not announced', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final store = _HeldUpdateStore();
        final h = _Harness([BuiltTransport(d.transport, presentedHostKey: 'FP')], store: store);
        store.add(sshProfile());
        async.flushMicrotasks();
        h.session.connect(sshProfile());
        async.flushMicrotasks();
        h.session.dispose();
        store.written.complete();
        async.flushMicrotasks();
        expect(h.profileChanges, 0); // nobody is left to refresh
        expect(d.transport.closed, isTrue);
      });
    });
  });

  group('reconnect', () {
    test('a lost event stream reconnects with backoff, swaps the transport and resumes from the cursor', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final d2 = FakeDaemon();
        final h = _Harness([d1.transport, d2.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        d1.events.add(utf8.encode(eventLine(timeNano: 1700000000000000123)));
        async.flushMicrotasks();
        expect(h.events, hasLength(1));
        d1.events.addError(const SocketException('reset'));
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.s.attempt, 1);
        async.elapse(const Duration(milliseconds: 999));
        expect(h.factory.builds, 1);
        async.elapse(const Duration(milliseconds: 2));
        expect(h.factory.builds, 2);
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.attempt, 0);
        expect(h.s.error, isNull);
        expect(h.s.transport, same(d2.transport));
        expect(d1.transport.closed, isTrue);
        expect(d2.eventOpens.last.query, {'since': '1700000000.000000123'});
      });
    });

    test('a cleanly closed event stream also reconnects', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final h = _Harness([d1.transport, FakeDaemon().transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        d1.events.close();
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting);
        async.elapse(const Duration(seconds: 2));
        expect(h.s.status, SessionStatus.connected);
      });
    });

    test('gives up after five attempts', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final h = _Harness([d1.transport, _down, _down, _down, _down, _down]);
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1 + 2 + 4 + 8 + 15));
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.s.attempt, 5);
        async.elapse(const Duration(seconds: 2));
        expect(h.s.status, SessionStatus.failed);
        expect(h.s.error!.message, 'down');
        expect(h.factory.builds, 6);
        async.elapse(const Duration(minutes: 5));
        expect(h.factory.builds, 6);
      });
    });

    test('a non-retryable error fails at once', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final h = _Harness([d1.transport, FakeDaemon(pingStatus: 401).transport]);
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1));
        expect(h.s.status, SessionStatus.failed);
        expect(h.s.error!.kind, DockerErrorKind.unauthorized);
        expect(h.factory.builds, 2);
      });
    });

    test('a host-key mismatch during reconnect fails with a clear message', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final h = _Harness([d1.transport, const HostKeyMismatchException('FP2')]);
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1));
        expect(h.s.status, SessionStatus.failed);
        expect(h.s.error!.message, contains('Host key changed'));
      });
    });

    test('retry() from failed tries again at once', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final d3 = FakeDaemon();
        final h = _Harness([d1.transport, FakeDaemon(pingStatus: 401).transport, d3.transport]);
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1));
        expect(h.s.status, SessionStatus.failed);
        h.session.retry();
        expect(h.s.status, SessionStatus.reconnecting);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.transport, same(d3.transport));
      });
    });

    test('disconnect during an in-flight attempt closes the late transport', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final d2 = FakeDaemon();
        final pending = Completer<BuiltTransport>();
        final h = _Harness([d1.transport, pending.future]);
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1));
        expect(h.factory.builds, 2);
        h.session.disconnect();
        async.flushMicrotasks();
        pending.complete(BuiltTransport(d2.transport));
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.disconnected);
        expect(h.s.transport, isNull);
        expect(d2.transport.closed, isTrue);
      });
    });

    test("a stale in-flight attempt does not block the next connection's reconnect", () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final d2 = FakeDaemon();
        final d3 = FakeDaemon();
        final stale = Completer<BuiltTransport>();
        final h = _Harness([d1.transport, stale.future, d2.transport, d3.transport]);
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1));
        expect(h.factory.builds, 2);
        h.session.connect(agentB);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.transport, same(d2.transport));
        d2.events.addError(const SocketException('reset'));
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting);
        async.elapse(const Duration(seconds: 1));
        expect(h.factory.builds, 4);
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.transport, same(d3.transport));
        final lateDaemon = FakeDaemon();
        stale.complete(BuiltTransport(lateDaemon.transport));
        async.flushMicrotasks();
        expect(lateDaemon.transport.closed, isTrue);
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.transport, same(d3.transport));
      });
    });

    test('disconnect while waiting cancels the loop', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final h = _Harness([d1.transport, FakeDaemon().transport]);
        connectThenLose(async, h, d1);
        h.session.disconnect();
        async.elapse(const Duration(minutes: 1));
        expect(h.factory.builds, 1);
        expect(h.s.status, SessionStatus.disconnected);
        expect(d1.transport.closed, isTrue);
      });
    });

    test('a successful reconnect asks for a full refresh once; a first connect does not', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final d2 = FakeDaemon();
        final h = _Harness([d1.transport, d2.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.connected);
        expect(h.invalidator.calls, isNot(contains('all')));
        d1.events.addError(const SocketException('reset'));
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1));
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.transport, same(d2.transport));
        expect(h.invalidator.calls.where((c) => c == 'all'), hasLength(1));
      });
    });

    test('a failed reconnect attempt asks for no refresh', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final h = _Harness([d1.transport, _down]);
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1));
        expect(h.factory.builds, 2);
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.s.attempt, 2);
        expect(h.invalidator.calls, isNot(contains('all')));
      });
    });

    test('refreshes pending when the stream is lost are dropped; the reconnect refreshes everything', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final d2 = FakeDaemon();
        // The first retry comes after every debounce window (0.5 s for lists and details, 2 s for the dashboard).
        final h = _Harness(
          [d1.transport, d2.transport],
          policy: ReconnectPolicy(base: const Duration(seconds: 5), jitter: 0),
        );
        h.session.connect(agentA);
        async.flushMicrotasks();
        d1.events.add(utf8.encode(eventLine(action: 'die', timeNano: 1700000000000000123)));
        async.flushMicrotasks();
        expect(h.events, hasLength(1));
        d1.events.addError(const SocketException('reset'));
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting);

        async.elapse(const Duration(seconds: 3));
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.invalidator.calls, isEmpty);

        async.elapse(const Duration(seconds: 2));
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.transport, same(d2.transport));
        expect(d2.eventOpens.single.query, {'since': '1700000000.000000123'});
        async.elapse(const Duration(seconds: 3));
        expect(h.invalidator.calls, ['all']);
      });
    });

    test('a refresh that throws after a reconnect leaves the new transport open', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final d2 = FakeDaemon();
        final h = _Harness([d1.transport, d2.transport], invalidator: _ThrowingInvalidator());
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1));
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.transport, same(d2.transport));
        expect(d2.transport.closed, isFalse);
      });
    });

    test('a refresh that throws after a reconnect still leaves the events stream open on the new transport', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final d2 = FakeDaemon();
        final h = _Harness([d1.transport, d2.transport, FakeDaemon().transport], invalidator: _ThrowingInvalidator());
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1));
        expect(h.s.status, SessionStatus.connected);
        expect(d2.eventOpens, hasLength(1));
        expect(d2.activeEventStreams, 1);

        // So the next loss is noticed too.
        d2.events.addError(const SocketException('reset'));
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting);
      });
    });

    test('an events stream that never stays up ends in failed after the attempt limit', () {
      fakeAsync((async) {
        // More daemons than the limit allows: without it the session would go through them all.
        final h = _Harness([for (var i = 0; i < 10; i++) _noEventsDaemon().transport]);
        final attempts = <int>[];
        h.session.addListener((s) {
          if (s.status == SessionStatus.reconnecting) attempts.add(s.attempt);
        }, fireImmediately: false);
        h.session.connect(agentA);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting); // connected, and the stream ended at once

        async.elapse(const Duration(seconds: 1 + 2 + 4 + 8)); // four reconnects, each lost again at once
        expect(attempts, [1, 2, 3, 4, 5]);
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.factory.builds, 5);

        async.elapse(const Duration(seconds: 16)); // the fifth holds no better
        expect(h.s.status, SessionStatus.failed);
        expect(h.s.error!.message, 'The daemon closed the event stream');
        expect(attempts, [1, 2, 3, 4, 5]);
        expect(h.factory.builds, 6);

        async.elapse(const Duration(minutes: 5));
        expect(h.s.status, SessionStatus.failed);
        expect(h.factory.builds, 6);
      });
    });

    test('a reconnect that holds for the policy cap starts the count again', () {
      fakeAsync((async) {
        final daemons = [for (var i = 0; i < 5; i++) FakeDaemon()];
        final h = _Harness([for (final d in daemons) d.transport]);
        void lose(FakeDaemon d) {
          d.events.addError(const SocketException('reset'));
          async.flushMicrotasks();
        }

        connectThenLose(async, h, daemons[0]);
        expect(h.s.attempt, 1);
        async.elapse(const Duration(seconds: 1));
        expect(h.s.transport, same(daemons[1].transport));

        // Lost at once: the count goes on.
        lose(daemons[1]);
        expect(h.s.attempt, 2);
        async.elapse(const Duration(seconds: 2));
        expect(h.s.transport, same(daemons[2].transport));

        // Lost just short of the cap (30 s), which runs from this reconnect and
        // not from the one before it: the count still goes on.
        async.elapse(const Duration(milliseconds: 29999));
        lose(daemons[2]);
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.s.attempt, 3);
        async.elapse(const Duration(seconds: 4));
        expect(h.s.transport, same(daemons[3].transport));

        // This one holds for the cap: the next loss is a new one.
        async.elapse(const Duration(seconds: 30));
        lose(daemons[3]);
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.s.attempt, 1);
      });
    });

    test('Retry after such a failure starts at attempt 1', () {
      fakeAsync((async) {
        final good = FakeDaemon();
        final h = _Harness([
          for (var i = 0; i < 6; i++) _noEventsDaemon().transport,
          good.transport,
          FakeDaemon().transport,
        ]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 1 + 2 + 4 + 8 + 16));
        expect(h.s.status, SessionStatus.failed);
        expect(h.factory.builds, 6);

        h.session.retry();
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.s.attempt, 1);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.transport, same(good.transport));

        // The count is the retry's own: one attempt used, not the five of the failure before it.
        good.events.addError(const SocketException('reset'));
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.s.attempt, 2);
      });
    });

    test('a new connection starts the count again and disconnect leaves no timer behind', () {
      fakeAsync((async) {
        final d1 = FakeDaemon(), d2 = FakeDaemon(), d3 = FakeDaemon();
        final h = _Harness([d1.transport, d2.transport, d3.transport, FakeDaemon().transport]);
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1));
        expect(h.s.transport, same(d2.transport)); // reconnected a moment ago: one attempt is counted

        h.session.disconnect();
        async.flushMicrotasks();
        expect(async.pendingTimers, isEmpty);

        connectThenLose(async, h, d3, profile: agentB);
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.s.attempt, 1);
      });
    });
  });

  group('lifecycle', () {
    test('backgrounding while connected pauses the events stream; foregrounding pings and resumes', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final h = _Harness([d.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        expect(d.activeEventStreams, 1);
        h.lifecycle.emit(AppLifecycleState.paused);
        async.flushMicrotasks();
        expect(h.s.foreground, isFalse);
        expect(d.activeEventStreams, 0);
        final pings = d.transport.calls.where((c) => c.path == '/_ping').length;
        h.lifecycle.emit(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(d.transport.calls.where((c) => c.path == '/_ping').length, pings + 1);
        expect(d.activeEventStreams, 1);
        expect(h.s.status, SessionStatus.connected);
      });
    });

    test('a failed ping on foreground starts reconnecting', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final h = _Harness([d.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        h.lifecycle.emit(AppLifecycleState.paused);
        d.transport.onGet('/_ping', (_) => http.Response('{"message":"gone"}', 500));
        h.lifecycle.emit(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting);
      });
    });

    test('backgrounding suspends the reconnect wait; foregrounding tries at once', () {
      fakeAsync((async) {
        final d1 = FakeDaemon();
        final h = _Harness([d1.transport, FakeDaemon().transport]);
        connectThenLose(async, h, d1);
        h.lifecycle.emit(AppLifecycleState.paused);
        async.elapse(const Duration(seconds: 10));
        expect(h.factory.builds, 1);
        h.lifecycle.emit(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(h.factory.builds, 2);
        expect(h.s.status, SessionStatus.connected);
      });
    });

    test('rapid lifecycle toggling leaves one events subscription', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final h = _Harness([d.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        h.lifecycle
          ..emit(AppLifecycleState.paused)
          ..emit(AppLifecycleState.resumed)
          ..emit(AppLifecycleState.paused)
          ..emit(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(d.activeEventStreams, 1);
        expect(h.s.status, SessionStatus.connected);
        expect(h.factory.builds, 1);
      });
    });

    test('inactive and hidden are ignored', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final h = _Harness([d.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        h.lifecycle
          ..emit(AppLifecycleState.inactive)
          ..emit(AppLifecycleState.hidden);
        async.flushMicrotasks();
        expect(h.s.foreground, isTrue);
        expect(d.activeEventStreams, 1);
      });
    });

    test('returning to the foreground with a good ping refreshes everything once and resumes from the cursor', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final h = _Harness([d.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        d.events.add(utf8.encode(eventLine(timeNano: 1700000000000000123)));
        async.elapse(const Duration(seconds: 3)); // the refreshes of that event are done
        h.invalidator.calls.clear();

        h.lifecycle.emit(AppLifecycleState.paused);
        async.elapse(const Duration(hours: 1)); // longer than the daemon keeps its backlog of events
        expect(h.invalidator.calls, isEmpty);

        h.lifecycle.emit(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.connected);
        expect(h.invalidator.calls, ['all']);
        expect(d.eventOpens, hasLength(2));
        expect(d.eventOpens.last.query, {'since': '1700000000.000000123'});
        expect(d.activeEventStreams, 1);
        async.elapse(const Duration(minutes: 1));
        expect(h.invalidator.calls, ['all']);
      });
    });

    test('a refresh pending when the app goes to the background never fires there', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final h = _Harness([d.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        d.events.add(utf8.encode(eventLine(action: 'die', timeNano: 1700000000000000123)));
        async.flushMicrotasks();
        expect(h.events, hasLength(1)); // seen: its refreshes wait for the debounce (0.5 s and 2 s)

        h.lifecycle.emit(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 5));
        expect(h.invalidator.calls, isEmpty);

        // The return makes up for them, and the event that was seen is not asked for again.
        h.lifecycle.emit(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(h.invalidator.calls, ['all']);
        expect(d.eventOpens.last.query, {'since': '1700000000.000000123'});
        async.elapse(const Duration(minutes: 1));
        expect(h.invalidator.calls, ['all']);
      });
    });

    final latePings = <String, void Function(Completer<void>)>{
      'fails': (ping) => ping.completeError(const SocketException('reset')),
      'answers': (ping) => ping.complete(),
    };
    for (final MapEntry(key: outcome, value: finish) in latePings.entries) {
      test('a resume ping that $outcome only after a reconnect leaves the new connection alone', () {
        fakeAsync((async) {
          final t1 = _PingsOnHold();
          final d2 = FakeDaemon();
          final h = _Harness([t1, d2.transport]);
          h.session.connect(agentA);
          async.flushMicrotasks();
          expect(h.s.status, SessionStatus.connected);

          // In the foreground again twice in a row: two pings are out on the old connection.
          h.lifecycle
            ..emit(AppLifecycleState.paused)
            ..emit(AppLifecycleState.resumed)
            ..emit(AppLifecycleState.paused)
            ..emit(AppLifecycleState.resumed);
          async.flushMicrotasks();
          expect(t1.pings, hasLength(2));

          // The second one fails and the session reconnects.
          t1.pings[1].completeError(const SocketException('reset'));
          async.flushMicrotasks();
          expect(h.s.status, SessionStatus.reconnecting);
          async.elapse(const Duration(seconds: 1));
          expect(h.s.status, SessionStatus.connected);
          expect(h.s.transport, same(d2.transport));
          expect(d2.eventOpens, hasLength(1));
          expect(h.invalidator.calls, ['all']);

          // The first one finishes only now. It was asked of the old connection and says nothing about this one.
          finish(t1.pings[0]);
          async.flushMicrotasks();
          expect(h.s.status, SessionStatus.connected);
          expect(h.s.transport, same(d2.transport));
          expect(d2.eventOpens, hasLength(1));
          expect(d2.activeEventStreams, 1);
          expect(h.invalidator.calls, ['all']);
          expect(h.factory.builds, 2);
        });
      });
    }

    test('a resume ping that answers after the app went to the background again opens and refreshes nothing', () {
      fakeAsync((async) {
        final t = _PingsOnHold();
        final h = _Harness([t]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        h.lifecycle
          ..emit(AppLifecycleState.paused)
          ..emit(AppLifecycleState.resumed)
          ..emit(AppLifecycleState.paused);
        async.flushMicrotasks();

        t.pings.single.complete();
        async.flushMicrotasks();
        expect(t.eventStreams, hasLength(1)); // the one the connect opened, cancelled since
        expect(t.eventStreams.single.hasListener, isFalse);
        expect(h.invalidator.calls, isEmpty);
      });
    });

    test('a resume ping that answers while the session is reconnecting opens and refreshes nothing', () {
      fakeAsync((async) {
        final t = _PingsOnHold();
        final h = _Harness([t, FakeDaemon().transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        h.lifecycle
          ..emit(AppLifecycleState.paused)
          ..emit(AppLifecycleState.resumed)
          ..emit(AppLifecycleState.paused)
          ..emit(AppLifecycleState.resumed);
        async.flushMicrotasks();
        t.pings[1].completeError(const SocketException('reset'));
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting);

        // The connection is taken for dead: a late answer on it must not be acted on.
        t.pings[0].complete();
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting);
        expect(t.eventStreams, hasLength(1));
        expect(h.invalidator.calls, isEmpty);
      });
    });

    test('a loss found on return to the foreground starts at attempt 1, however soon after a reconnect', () {
      fakeAsync((async) {
        final d1 = FakeDaemon(), d2 = FakeDaemon();
        final h = _Harness([d1.transport, d2.transport, FakeDaemon().transport]);
        connectThenLose(async, h, d1);
        async.elapse(const Duration(seconds: 1));
        expect(h.s.transport, same(d2.transport)); // reconnected this instant: far from settled

        // The app goes away at once, and the connection dies while it is away.
        h.lifecycle.emit(AppLifecycleState.paused);
        d2.transport.throwOn('GET', '/_ping', const SocketException('reset'));
        h.lifecycle.emit(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(h.s.status, SessionStatus.reconnecting);
        expect(h.s.attempt, 1);
      });
    });

    test('five short visits that each find the connection dead never end in failed', () {
      fakeAsync((async) {
        final daemons = [for (var i = 0; i < 7; i++) FakeDaemon()];
        final h = _Harness([for (final d in daemons) d.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();

        // Come back, find the connection dead, look for 20 s (less than the
        // 30 s cap) and lock the phone: five times, and then come back once
        // more. No time passes in the background.
        final found = <String>[];
        for (var visit = 1; visit <= 6; visit++) {
          h.lifecycle.emit(AppLifecycleState.paused);
          daemons[visit - 1].transport.throwOn('GET', '/_ping', const SocketException('reset'));
          h.lifecycle.emit(AppLifecycleState.resumed);
          async.flushMicrotasks();
          found.add('${h.s.status.name} ${h.s.attempt}');
          async.elapse(const Duration(seconds: 20));
        }
        expect(found, List.filled(6, 'reconnecting 1'));
        expect(h.s.status, SessionStatus.connected);
        expect(h.s.transport, same(daemons[6].transport));
        expect(h.factory.builds, 7); // the connect and one reconnect for every return
      });
    });
  });

  group('events', () {
    test('events reach the feed callback and refresh lists', () {
      fakeAsync((async) {
        final d = FakeDaemon();
        final h = _Harness([d.transport]);
        h.session.connect(agentA);
        async.flushMicrotasks();
        d.events.add(utf8.encode(eventLine()));
        async.elapse(const Duration(milliseconds: 600));
        expect(h.events, hasLength(1));
        expect(h.invalidator.calls, contains('list:container'));
      });
    });
  });

  test('disconnect closes the transport, stops events and resets the state', () {
    fakeAsync((async) {
      final d = FakeDaemon();
      final h = _Harness([d.transport]);
      h.session.connect(agentA);
      async.flushMicrotasks();
      h.session.disconnect();
      async.flushMicrotasks();
      expect(h.s.status, SessionStatus.disconnected);
      expect(h.s.transport, isNull);
      expect(h.s.sessionId, 1);
      expect(d.transport.closed, isTrue);
      expect(d.activeEventStreams, 0);
    });
  });

  test('dispose during an in-flight connect closes the late transport and never writes state', () {
    fakeAsync((async) {
      final d = FakeDaemon();
      final pending = Completer<BuiltTransport>();
      final h = _Harness([pending.future]);
      h.session.connect(agentA);
      async.flushMicrotasks();
      h.session.dispose();
      pending.complete(BuiltTransport(d.transport));
      async.flushMicrotasks();
      expect(d.transport.closed, isTrue);
      expect(d.transport.calls, isEmpty);
    });
  });

  test('dispose closes the transport', () {
    fakeAsync((async) {
      final d = FakeDaemon();
      final h = _Harness([d.transport]);
      h.session.connect(agentA);
      async.flushMicrotasks();
      h.session.dispose();
      async.flushMicrotasks();
      expect(d.transport.closed, isTrue);
    });
  });
}
