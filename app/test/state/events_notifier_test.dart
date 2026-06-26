import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/state/events_notifier.dart';

class _FakeTransport implements Transport {
  final Stream<List<int>> Function() build;
  _FakeTransport(this.build);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => build();
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{}', 200);
  @override
  Future<http.Response> post(String path, {Map<String, String>? query, Object? body, Map<String, String>? headers}) async => http.Response('', 200);
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) => throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
  @override
  Future<void> close() async {}
}

void main() {
  test('prepends newest-first, caps the buffer, and filters by type', () async {
    final lines = StringBuffer();
    for (var i = 0; i < kEventsBufferCap + 5; i++) {
      lines.writeln('{"Type":"container","Action":"start","Actor":{"Attributes":{"name":"c$i"}}}');
    }
    lines.writeln('{"Type":"image","Action":"pull","Actor":{"Attributes":{"name":"nginx"}}}');
    final client = DockerApiClient(_FakeTransport(() => Stream.value(utf8.encode(lines.toString()))));
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
    final client = DockerApiClient(_FakeTransport(() => Stream.error(Exception('boom'))));
    final n = EventsNotifier(client);
    await pumpEventQueue();
    expect(n.state.status, EventsStatus.error);
    expect(n.state.error, contains('boom'));
    n.dispose();
  });
}
