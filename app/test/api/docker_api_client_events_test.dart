import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

import '../support/fake_transport.dart';

void main() {
  test('streamEvents parses NDJSON across chunk boundaries', () async {
    final l1 = '{"Type":"container","Action":"start","Actor":{"Attributes":{"name":"a"}}}';
    final l2 = '{"Type":"image","Action":"pull","Actor":{"Attributes":{"name":"nginx"}}}';
    final all = '$l1\n$l2\n';
    final cut = l1.length - 4;
    final t = FakeTransport.streaming(
        Stream.fromIterable([utf8.encode(all.substring(0, cut)), utf8.encode(all.substring(cut))]));
    final events = await DockerApiClient(t).streamEvents().toList();

    expect(t.lastPath, '/events');
    expect(events.length, 2);
    expect(events[0].type, 'container');
    expect(events[1].target, 'nginx');
  });

  test('skips a malformed NDJSON line', () async {
    final t = FakeTransport.streaming(
        Stream.fromIterable([utf8.encode('garbage\n{"Type":"volume","Action":"create"}\n')]));
    final events = await DockerApiClient(t).streamEvents().toList();
    expect(events.length, 1);
    expect(events.single.type, 'volume');
  });

  test('events since is passed through when given', () async {
    final t = FakeTransport()..onStream(RegExp('.*'), (_) => const Stream.empty());
    final client = DockerApiClient(t);
    await client.streamEvents(since: '1700000000.5').toList();
    expect(t.lastQuery, {'since': '1700000000.5'});
    await client.streamEvents().toList();
    expect(t.lastQuery, isNull);
  });
}
