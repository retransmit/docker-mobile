import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/session/events_hub.dart';
import 'package:docker_mobile/src/session/lifecycle_source.dart';
import 'package:docker_mobile/src/session/reconnect_policy.dart';
import 'package:docker_mobile/src/session/transport_factory.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';
import 'package:docker_mobile/src/transport/transport.dart';

import 'fake_transport.dart';

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

/// An SSH connection that presents [fingerprint] and fails with
/// [connectError] (after the host-key check) when set.
class FakeSshConnection implements SshConnection {
  final String fingerprint;
  final Object? connectError;
  bool closed = false;
  FakeSshConnection(this.fingerprint, {this.connectError});

  @override
  Future<void> connect({required HostKeyVerifier verifyHostKey}) async {
    if (!verifyHostKey(fingerprint)) throw Exception('host key rejected');
    final e = connectError;
    if (e != null) throw e;
  }

  @override
  Future<Duplex> openChannel() async => Duplex(input: const Stream.empty(), add: (_) {}, close: () async {});

  @override
  Future<void> close() async => closed = true;
}

/// Hands out queued results in order. A result is a [Transport], a
/// [BuiltTransport], a Future of either, or anything else to throw.
class FakeTransportFactory implements TransportFactory {
  FakeTransportFactory(List<Object> results) : _results = List.of(results);
  final List<Object> _results;
  final pinOverrides = <String?>[];
  final profiles = <ConnectionProfile>[];
  int builds = 0;

  void enqueue(Object result) => _results.add(result);

  @override
  Future<BuiltTransport> build(ConnectionProfile profile, {String? pinOverride}) async {
    builds++;
    pinOverrides.add(pinOverride);
    profiles.add(profile);
    if (_results.isEmpty) throw StateError('FakeTransportFactory: no result queued for build #$builds');
    final r = _results.removeAt(0);
    final Object? v = r is Future ? await r : r;
    if (v == null) throw StateError('FakeTransportFactory: queued result completed with null');
    if (v is BuiltTransport) return v;
    if (v is Transport) return BuiltTransport(v);
    throw v;
  }
}

/// A daemon behind a [FakeTransport]: answers /_ping and /version, and opens
/// a fresh controllable events stream on every subscription.
class FakeDaemon {
  FakeDaemon({String apiVersion = '1.46', int pingStatus = 200}) {
    transport
      ..onGet('/_ping', (_) => http.Response(pingStatus == 200 ? 'OK' : '{"message":"ping failed"}', pingStatus))
      ..onGet('/version', (_) => http.Response(jsonEncode({'Version': '27.0', 'ApiVersion': apiVersion}), 200))
      ..onStream(RegExp(r'/events$'), (_) {
        final c = StreamController<List<int>>(
          onListen: () => activeEventStreams++,
          onCancel: () => activeEventStreams--,
        );
        eventStreams.add(c);
        return c.stream;
      });
  }

  final transport = FakeTransport();
  final eventStreams = <StreamController<List<int>>>[];
  int activeEventStreams = 0;

  /// The most recently opened events stream.
  StreamController<List<int>> get events => eventStreams.last;

  List<RecordedCall> get eventOpens =>
      transport.calls.where((c) => c.method == 'STREAM' && c.path.endsWith('/events')).toList();
}

/// A [FakeDaemon] that also has container `a`, a TTY (so its log bytes are
/// sent unframed): the inspect answers, and every logs or stats open gets a
/// stream that stays open. The test writes log bytes to [logs].
class FakeContainerDaemon extends FakeDaemon {
  FakeContainerDaemon() {
    transport
      ..onGet(RegExp(r'/containers/a/json$'), (_) => http.Response(
            '{"Id":"a","Name":"/web","Config":{"Image":"nginx","Tty":true},"State":{"Status":"running"}}',
            200,
          ))
      ..onStream(RegExp(r'/containers/a/logs$'), (_) => (logs = StreamController<List<int>>()).stream)
      ..onStream(RegExp(r'/containers/a/stats$'), (_) => StreamController<List<int>>().stream);
  }

  /// The most recently opened logs stream.
  late StreamController<List<int>> logs;

  List<RecordedCall> get logOpens => _opens('logs');

  List<RecordedCall> get statsOpens => _opens('stats');

  List<RecordedCall> _opens(String stream) =>
      transport.calls.where((c) => c.method == 'STREAM' && c.path.endsWith('/containers/a/$stream')).toList();
}

/// Two log timestamps one nanosecond apart, in the daemon's format.
const firstLogStamp = '2026-01-02T03:04:05.000000001Z';
const secondLogStamp = '2026-01-02T03:04:05.000000002Z';

/// One NDJSON line of a Docker event.
String eventLine({String type = 'container', String action = 'start', String id = 'c1', int? timeNano}) =>
    '${jsonEncode({
      'Type': type,
      'Action': action,
      'Actor': {'ID': id, 'Attributes': {'name': 'web'}},
      'timeNano': ?timeNano,
    })}\n';

/// Records invalidations as strings: `list:<category>`, `detail:<category>:<id>`, `dashboard`, `all`.
class RecordingInvalidator implements Invalidator {
  final calls = <String>[];

  @override
  void list(EventCategory category) => calls.add('list:${category.name}');

  @override
  void detail(EventCategory category, String id) => calls.add('detail:${category.name}:$id');

  @override
  void dashboard() => calls.add('dashboard');

  @override
  void all() => calls.add('all');
}
