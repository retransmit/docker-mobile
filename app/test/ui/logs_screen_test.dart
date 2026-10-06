import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/logs_screen.dart';

import '../support/fake_transport.dart';
import '../support/stub_session.dart';

List<int> frame(int type, List<int> p) {
  final n = p.length;
  return [type, 0, 0, 0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, ...p];
}

FakeTransport logsFake({List<int>? logBytes}) => FakeTransport()
  ..onGet('/containers/a/json', (_) => http.Response(
        '{"Id":"a","Name":"/web","Config":{"Image":"nginx","Tty":false},"State":{"Status":"running"}}',
        200,
      ))
  ..onStream('/containers/a/logs', (_) {
    final bytes = logBytes ??
        [...frame(1, utf8.encode('hello-out\n')), ...frame(2, utf8.encode('oops-err\n'))];
    return Stream.value(bytes);
  });

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: LogsScreen(containerId: 'a', containerName: 'web')),
    );

void main() {
  testWidgets('renders streamed log lines', (tester) async {
    await tester.pumpWidget(_wrap(logsFake()));
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget); // app bar title
    expect(find.textContaining('hello-out', findRichText: true), findsOneWidget);
    expect(find.textContaining('oops-err', findRichText: true), findsOneWidget);
  });

  testWidgets('search filters the rendered lines', (tester) async {
    await tester.pumpWidget(_wrap(logsFake()));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'oops');
    await tester.pumpAndSettle();

    expect(find.textContaining('oops-err', findRichText: true), findsOneWidget);
    expect(find.textContaining('hello-out', findRichText: true), findsNothing);
  });

  testWidgets('jump-to-latest FAB appears when scrolled up', (tester) async {
    final many = '${List.generate(200, (i) => 'line$i').join('\n')}\n';
    await tester.pumpWidget(_wrap(logsFake(logBytes: frame(1, utf8.encode(many)))));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.arrow_downward), findsNothing); // at bottom
    await tester.drag(find.byType(ListView), const Offset(0, 400)); // scroll toward top
    await tester.pump();

    expect(find.byIcon(Icons.arrow_downward), findsOneWidget);
  });

  testWidgets('the tail menu refetches with the chosen size, and with All', (tester) async {
    final t = logsFake();
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();
    List<RecordedCall> opens() => t.calls.where((c) => c.method == 'STREAM').toList();
    expect(opens(), hasLength(1));

    await tester.tap(find.byTooltip('Tail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tail 100'));
    await tester.pumpAndSettle();
    expect(opens(), hasLength(2));
    expect(opens().last.query!['tail'], '100');

    await tester.tap(find.byTooltip('Tail'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All'));
    await tester.pumpAndSettle();
    expect(opens(), hasLength(3));
    expect(opens().last.query!['tail'], 'all');
  });

  testWidgets('a failed first inspect shows the error banner with Retry', (tester) async {
    final t = FakeTransport()
      ..onGet('/containers/a/json', (_) => http.Response('{"message":"No such container: a"}', 404));
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    expect(find.byType(MaterialBanner), findsOneWidget);
    expect(find.text('No such container: a'), findsOneWidget);
    expect(t.calls.where((c) => c.method == 'STREAM'), isEmpty); // no body, so no log stream

    await tester.tap(find.widgetWithText(TextButton, 'Retry'));
    await tester.pumpAndSettle();
    expect(t.calls.where((c) => c.method == 'GET'), hasLength(2)); // Retry asks the daemon again
    expect(find.byType(MaterialBanner), findsOneWidget);
  });

  testWidgets('a reconnecting session shows the reconnecting row and keeps the lines', (tester) async {
    late StreamController<List<int>> logs; // the most recently opened log stream
    final t = logsFake()..onStream('/containers/a/logs', (_) => (logs = StreamController<List<int>>()).stream);
    final connected = SessionState(status: SessionStatus.connected, transport: t, sessionId: 1);
    final stub = StubSession(connected);
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWith((ref) => stub)],
      child: const MaterialApp(home: LogsScreen(containerId: 'a', containerName: 'web')),
    ));
    await tester.pumpAndSettle();
    logs.add(frame(1, utf8.encode('hello-out\n')));
    await tester.pumpAndSettle();
    expect(find.textContaining('hello-out', findRichText: true), findsOneWidget);
    expect(find.text('Reconnecting stream...'), findsNothing);

    stub.setState(connected.copyWith(status: SessionStatus.reconnecting, attempt: 1));
    await tester.pump();
    expect(find.text('Reconnecting stream...'), findsOneWidget);
    expect(find.textContaining('hello-out', findRichText: true), findsOneWidget);

    stub.setState(connected);
    await tester.pumpAndSettle();
    expect(find.text('Reconnecting stream...'), findsNothing);
  });

  testWidgets('a session that gave up shows Connection lost in place of the reconnecting row', (tester) async {
    late StreamController<List<int>> logs; // the most recently opened log stream
    final t = logsFake()..onStream('/containers/a/logs', (_) => (logs = StreamController<List<int>>()).stream);
    final connected = SessionState(status: SessionStatus.connected, transport: t, sessionId: 1);
    final stub = StubSession(connected);
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWith((ref) => stub)],
      child: const MaterialApp(home: LogsScreen(containerId: 'a', containerName: 'web')),
    ));
    await tester.pumpAndSettle();
    logs.add(frame(1, utf8.encode('hello-out\n')));
    await tester.pumpAndSettle();

    // While the session retries, the stream waits for it and says so.
    stub.setState(connected.copyWith(status: SessionStatus.reconnecting, attempt: 1));
    await tester.pump();
    expect(find.text('Reconnecting stream...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Connection lost'), findsNothing);

    // Once it gives up, nothing is reconnecting any more.
    stub.setState(connected.copyWith(status: SessionStatus.failed));
    await tester.pump();
    expect(find.text('Connection lost'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off), findsOneWidget);
    expect(find.text('Reconnecting stream...'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('hello-out', findRichText: true), findsOneWidget);
  });
}
