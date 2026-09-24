import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/events_notifier.dart';

import '../support/fake_transport.dart';

void main() {
  test('prepends newest-first, caps the buffer, and filters by type', () async {
    final lines = StringBuffer();
    for (var i = 0; i < kEventsBufferCap + 5; i++) {
      lines.writeln('{"Type":"container","Action":"start","Actor":{"Attributes":{"name":"c$i"}}}');
    }
    lines.writeln('{"Type":"image","Action":"pull","Actor":{"Attributes":{"name":"nginx"}}}');
    final client = DockerApiClient(
        FakeTransport()..onStream('/events', (_) => Stream.value(utf8.encode(lines.toString()))));
    final n = EventsNotifier(client);
    await pumpEventQueue();

    expect(n.state.events.length, kEventsBufferCap); // capped
    expect(n.state.events.first.target, 'nginx'); // newest first (last fed)
    expect(n.state.visibleEvents.length, kEventsBufferCap); // no filter

    n.setFilter('image');
    expect(n.state.visibleEvents.length, 1);
    expect(n.state.visibleEvents.single.type, 'image');

    n.setFilter(null);
    expect(n.state.visibleEvents.length, kEventsBufferCap);
    n.dispose();
  });

  test('a stream error sets error status', () async {
    final client = DockerApiClient(
        FakeTransport()..onStream('/events', (_) => Stream.error(Exception('boom'))));
    final n = EventsNotifier(client);
    await pumpEventQueue();
    expect(n.state.status, EventsStatus.error);
    expect(n.state.error, contains('boom'));
    n.dispose();
  });
}
