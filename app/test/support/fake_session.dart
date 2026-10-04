import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
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
    final Object v = r is Future ? await r as Object : r;
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

  List<RecordedCall> get eventOpens => transport.calls.where((c) => c.method == 'STREAM').toList();
}

/// One NDJSON line of a Docker event.
String eventLine({String type = 'container', String action = 'start', String id = 'c1', int? timeNano}) =>
    '${jsonEncode({
      'Type': type,
      'Action': action,
      'Actor': {'ID': id, 'Attributes': {'name': 'web'}},
      'timeNano': ?timeNano,
    })}\n';
