import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/events_screen.dart';
import 'package:docker_mobile/src/ui/system_screen.dart';

class _FakeTransport implements Transport {
  final List<int>? eventsBytes;
  _FakeTransport({this.eventsBytes});
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) =>
      (path == '/events' && eventsBytes != null) ? Stream.value(eventsBytes!) : const Stream.empty();
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path == '/info') return http.Response('{"ServerVersion":"27","NCPU":1,"Driver":"overlay2"}', 200);
    if (path == '/version') return http.Response('{"Version":"27","ApiVersion":"1.46"}', 200);
    if (path == '/system/df') return http.Response('{"Images":[],"Containers":[],"Volumes":[],"BuildCache":[]}', 200);
    return http.Response('{}', 200);
  }
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

const _events =
    '{"Type":"container","Action":"start","Actor":{"Attributes":{"name":"web"}}}\n'
    '{"Type":"image","Action":"pull","Actor":{"Attributes":{"name":"nginx"}}}\n';

Widget _wrap(Transport t, Widget child) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('renders events; the Containers chip filters the feed', (tester) async {
    await tester.pumpWidget(_wrap(_FakeTransport(eventsBytes: utf8.encode(_events)), const EventsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('nginx'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Containers'));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('nginx'), findsNothing); // image filtered out
  });

  testWidgets('the System Events action opens the events screen', (tester) async {
    await tester.pumpWidget(_wrap(_FakeTransport(), const SystemScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pumpAndSettle();
    expect(find.byType(EventsScreen), findsOneWidget);
    expect(find.textContaining('No events'), findsOneWidget);
  });
}
