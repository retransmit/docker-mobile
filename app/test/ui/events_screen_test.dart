import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/events_screen.dart';
import 'package:docker_mobile/src/ui/system_screen.dart';

import '../support/fake_transport.dart';

FakeTransport eventsFake({List<int>? eventsBytes}) => FakeTransport()
  ..onStream('/events', (_) => eventsBytes == null ? const Stream.empty() : Stream.value(eventsBytes))
  ..onGet('/info', (_) => http.Response('{"ServerVersion":"27","NCPU":1,"Driver":"overlay2"}', 200))
  ..onGet('/version', (_) => http.Response('{"Version":"27","ApiVersion":"1.46"}', 200))
  ..onGet('/system/df', (_) => http.Response('{"Images":[],"Containers":[],"Volumes":[],"BuildCache":[]}', 200));

const _events =
    '{"Type":"container","Action":"start","Actor":{"Attributes":{"name":"web"}}}\n'
    '{"Type":"image","Action":"pull","Actor":{"Attributes":{"name":"nginx"}}}\n';

Widget _wrap(Transport t, Widget child) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: MaterialApp(home: child),
    );

void main() {
  testWidgets('renders events; the Containers chip filters the feed', (tester) async {
    await tester.pumpWidget(_wrap(eventsFake(eventsBytes: utf8.encode(_events)), const EventsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('nginx'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Containers'));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('nginx'), findsNothing); // image filtered out
  });

  testWidgets('the System Events action opens the events screen', (tester) async {
    await tester.pumpWidget(_wrap(eventsFake(), const SystemScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pumpAndSettle();
    expect(find.byType(EventsScreen), findsOneWidget);
    expect(find.textContaining('No events'), findsOneWidget);
  });
}
