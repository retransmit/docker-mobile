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
    final n = StatsNotifier(client, 'a');
    await pumpEventQueue();
    expect(n.state.status, StatsStatus.streaming);
    expect(n.state.latest, isNotNull);
    expect(n.state.cpuHistory.length, kStatsWindow); // capped
    expect(n.state.memHistory.length, kStatsWindow);
    n.dispose();
  });

  test('a stream error sets error status', () async {
    final client = DockerApiClient(
        FakeTransport()..onStream('/containers/a/stats', (_) => Stream.error(Exception('boom'))));
    final n = StatsNotifier(client, 'a');
    await pumpEventQueue();
    expect(n.state.status, StatsStatus.error);
    expect(n.state.error, contains('boom'));
    n.dispose();
  });
}
