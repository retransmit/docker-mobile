import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/stats_notifier.dart';

import '../support/fake_transport.dart';

String _line(int total) =>
    '{"cpu_stats":{"cpu_usage":{"total_usage":$total},"system_cpu_usage":2000000000,"online_cpus":1},'
    '"precpu_stats":{"cpu_usage":{"total_usage":0},"system_cpu_usage":1000000000},'
    '"memory_stats":{"usage":50,"limit":100}}';

void main() {
  test('samples update latest and grow the rolling windows (capped)', () async {
    final lines = '${[for (var i = 0; i < kStatsWindow + 5; i++) _line((i + 1) * 1000000)].join('\n')}\n';
    final client = DockerApiClient(
        FakeTransport()..onStream('/containers/a/stats', (_) => Stream.value(utf8.encode(lines))));
    final n = StatsNotifier(() => client, 'a');
    await pumpEventQueue();
    expect(n.state.status, StatsStatus.streaming);
    expect(n.state.latest, isNotNull);
    expect(n.state.cpuHistory.length, kStatsWindow); // capped
    expect(n.state.memHistory.length, kStatsWindow);
    n.dispose();
  });

  test('a stream error sets error status', () async {
    final client = DockerApiClient(
        FakeTransport()..onStream('/containers/a/stats', (_) => Stream.error(DockerError.fromResponse(404, '{"message":"boom"}'))));
    final n = StatsNotifier(() => client, 'a');
    await pumpEventQueue();
    expect(n.state.status, StatsStatus.error);
    expect(n.state.error!.message, 'boom');
    n.dispose();
  });

  test('setLive(false) shows reconnecting; setLive(true) reopens the stream', () async {
    final t = FakeTransport()..onStream('/containers/a/stats', (_) => StreamController<List<int>>().stream);
    final n = StatsNotifier(() => DockerApiClient(t), 'a');
    await pumpEventQueue();
    n.setLive(false);
    expect(n.state.status, StatsStatus.reconnecting);
    n.setLive(true);
    await pumpEventQueue();
    expect(t.calls.where((c) => c.method == 'STREAM'), hasLength(2));
    n.dispose();
  });

  test('a retry that opens before any sample shows loading and clears the error', () async {
    var opens = 0;
    final t = FakeTransport()
      ..onStream('/containers/a/stats', (_) {
        opens++;
        if (opens == 1) return Stream.error(DockerError.fromResponse(404, '{"message":"boom"}'));
        return StreamController<List<int>>().stream; // open, no sample yet
      });
    final n = StatsNotifier(() => DockerApiClient(t), 'a');
    await pumpEventQueue();
    expect(n.state.status, StatsStatus.error);

    n.retry();
    await pumpEventQueue();
    expect(n.state.status, StatsStatus.loading);
    expect(n.state.error, isNull);
    n.dispose();
  });

  test('the session coming back reopens a stream that had ended', () async {
    final t = FakeTransport()
      ..onStream('/containers/a/stats', (_) => Stream.value(utf8.encode('${_line(1000000)}\n')));
    final n = StatsNotifier(() => DockerApiClient(t), 'a');
    await pumpEventQueue();
    expect(t.calls.where((c) => c.method == 'STREAM'), hasLength(1));

    n.setLive(false);
    n.setLive(true);
    await pumpEventQueue();

    expect(t.calls.where((c) => c.method == 'STREAM'), hasLength(2));
    expect(n.state.cpuHistory, hasLength(1)); // kept; the reopened stream's first sample is dropped
    n.dispose();
  });

  test('the session coming back reopens a stream that had failed', () async {
    final t = FakeTransport()
      ..onStream('/containers/a/stats', (_) => Stream.error(DockerError.fromResponse(404, '{"message":"boom"}')));
    final n = StatsNotifier(() => DockerApiClient(t), 'a');
    await pumpEventQueue();
    expect(n.state.status, StatsStatus.error);

    n.setLive(false);
    n.setLive(true);
    await pumpEventQueue();

    expect(t.calls.where((c) => c.method == 'STREAM'), hasLength(2));
    n.dispose();
  });

  test('retry is ignored while the session is away', () async {
    final t = FakeTransport()..onStream('/containers/a/stats', (_) => StreamController<List<int>>().stream);
    final n = StatsNotifier(() => DockerApiClient(t), 'a');
    await pumpEventQueue();

    n.setLive(false);
    n.retry();
    await pumpEventQueue();
    expect(t.calls.where((c) => c.method == 'STREAM'), hasLength(1));
    expect(n.state.status, StatsStatus.reconnecting);
    n.dispose();
  });

  test('a reopened stream drops its first sample and appends the next', () async {
    final controllers = <StreamController<List<int>>>[];
    final t = FakeTransport()
      ..onStream('/containers/a/stats', (_) {
        final c = StreamController<List<int>>();
        controllers.add(c);
        return c.stream;
      });
    final n = StatsNotifier(() => DockerApiClient(t), 'a');
    controllers.last.add(utf8.encode('${_line(1000000)}\n'));
    await pumpEventQueue();
    expect(n.state.cpuHistory, hasLength(1));
    final shown = n.state.latest;

    n.setLive(false);
    n.setLive(true);
    controllers.last.add(utf8.encode('${_line(2000000)}\n')); // no previous CPU reading behind it
    await pumpEventQueue();
    expect(n.state.cpuHistory, hasLength(1));
    expect(n.state.memHistory, hasLength(1));
    expect(n.state.latest, same(shown));

    controllers.last.add(utf8.encode('${_line(3000000)}\n'));
    await pumpEventQueue();
    expect(n.state.cpuHistory, hasLength(2));
    expect(n.state.memHistory, hasLength(2));
    expect(n.state.latest, isNot(same(shown)));
    n.dispose();
  });
}
