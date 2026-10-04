import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/api/models/docker_event.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/events_screen.dart';
import 'package:docker_mobile/src/ui/system_screen.dart';
import 'package:docker_mobile/src/ui/widgets/error_view.dart';

import '../support/fake_transport.dart';
import '../support/stub_session.dart';

void main() {
  testWidgets('renders the session feed; the Containers chip filters it', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionEventsProvider.notifier)
      ..add(const DockerEvent(type: 'image', action: 'pull', target: 'nginx'))
      ..add(const DockerEvent(type: 'container', action: 'start', target: 'web'));
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: EventsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('nginx'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilterChip, 'Containers'));
    await tester.pumpAndSettle();
    expect(find.text('web'), findsOneWidget);
    expect(find.text('nginx'), findsNothing);
  });

  testWidgets('events added while the screen is open appear live', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: EventsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('No events'), findsOneWidget);
    container.read(sessionEventsProvider.notifier).add(const DockerEvent(type: 'container', action: 'die', target: 'db'));
    await tester.pumpAndSettle();
    expect(find.text('db'), findsOneWidget);
  });

  testWidgets('the System Events action opens the events screen', (tester) async {
    final t = FakeTransport()
      ..onGet('/info', (_) => http.Response('{"ServerVersion":"27","NCPU":1,"Driver":"overlay2"}', 200))
      ..onGet('/version', (_) => http.Response('{"Version":"27","ApiVersion":"1.46"}', 200))
      ..onGet('/system/df', (_) => http.Response('{"Images":[],"Containers":[],"Volumes":[],"BuildCache":[]}', 200));
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: SystemScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.bolt));
    await tester.pumpAndSettle();
    expect(find.byType(EventsScreen), findsOneWidget);
    expect(find.textContaining('No events'), findsOneWidget);
  });

  testWidgets('a failed session shows an ErrorView whose Retry retries the session', (tester) async {
    final stub = StubSession(const SessionState(
      status: SessionStatus.failed,
      error: DockerError(DockerErrorKind.network, 'Cannot reach the daemon: refused'),
    ));
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWith((ref) => stub)],
      child: const MaterialApp(home: EventsScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('Cannot reach the daemon: refused'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(stub.retries, 1);
  });
}
