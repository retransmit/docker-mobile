import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

import '../support/fake_transport.dart';

String _statsLine(int total) =>
    '{"cpu_stats":{"cpu_usage":{"total_usage":$total},"system_cpu_usage":2000000000,"online_cpus":1},'
    '"precpu_stats":{"cpu_usage":{"total_usage":0},"system_cpu_usage":1000000000},'
    '"memory_stats":{"usage":50,"limit":100}}';

void main() {
  test('streamContainerStats requests the stream and parses NDJSON across chunks', () async {
    final l1 = _statsLine(100000000);
    final l2 = _statsLine(200000000);
    // Split the NDJSON mid-first-line across two chunks.
    final all = '$l1\n$l2\n';
    final cut = l1.length - 3;
    final t = FakeTransport.streaming(
        Stream.fromIterable([utf8.encode(all.substring(0, cut)), utf8.encode(all.substring(cut))]));
    final stats = await DockerApiClient(t).streamContainerStats('abc').toList();

    expect(t.lastPath, '/containers/abc/stats');
    expect(t.lastQuery, {'stream': 'true'});
    expect(stats.length, 2);
    expect(stats[0].memoryUsed, 50);
  });

  test('skips a malformed NDJSON line', () async {
    final t = FakeTransport.streaming(Stream.fromIterable([utf8.encode('not json\n${_statsLine(1)}\n')]));
    final stats = await DockerApiClient(t).streamContainerStats('abc').toList();
    expect(stats.length, 1);
  });
}
