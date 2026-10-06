import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:xterm/xterm.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/ui/exec_screen.dart';

import '../support/fake_transport.dart';
import '../support/stub_session.dart';

void main() {
  testWidgets('renders the terminal and command bar, then shows session ended', (tester) async {
    final fake = FakeTransport()
      ..onGet(RegExp(r'/exec/[^/]+/json$'), (_) => http.Response('{"Running":false,"ExitCode":0}', 200))
      ..onPost(RegExp('.*'), (_) => http.Response('{"Id":"e1"}', 201)); // exec create and resize
    await tester.pumpWidget(
      ProviderScope(
        overrides: [transportProvider.overrideWith((ref) => fake)],
        child: const MaterialApp(home: ExecScreen(containerId: 'a', containerName: 'web')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget); // app bar title
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); // command bar

    await fake.lastChannel.controller.close(); // process exits
    await tester.pumpAndSettle();
    expect(find.textContaining('ended'), findsOneWidget);
  });

  FakeTransport freshExecFake() => FakeTransport()
    ..onPost(RegExp(r'/exec$'), (_) => http.Response('{"Id":"e1"}', 201))
    ..onPost(RegExp(r'/resize$'), (_) => http.Response('', 200))
    ..onGet(RegExp(r'/exec/[^/]+/json$'), (_) => http.Response('{"Running":false,"ExitCode":0}', 200));

  testWidgets('a transport swap ends the terminal; New session starts on the new connection', (tester) async {
    final t1 = freshExecFake();
    final t2 = freshExecFake();
    final current = StateProvider<Transport?>((ref) => t1);
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => ref.watch(current))],
      child: MaterialApp(home: Builder(builder: (ctx) {
        container = ProviderScope.containerOf(ctx);
        return const ExecScreen(containerId: 'abc', containerName: 'web');
      })),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(t1.posts.where((c) => c.path.endsWith('/exec')), hasLength(1));

    container.read(current.notifier).state = t2;
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Session ended'), findsOneWidget);
    expect(t1.lastChannel.closed, isTrue);

    await tester.tap(find.text('New session'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(t2.posts.where((c) => c.path.endsWith('/exec')), hasLength(1));
    expect(find.textContaining('Session ended'), findsNothing);
  });

  testWidgets('Run after a transport swap starts on the new connection with the typed command, once',
      (tester) async {
    final t1 = freshExecFake();
    final t2 = freshExecFake();
    final current = StateProvider<Transport?>((ref) => t1);
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => ref.watch(current))],
      child: MaterialApp(home: Builder(builder: (ctx) {
        container = ProviderScope.containerOf(ctx);
        return const ExecScreen(containerId: 'abc', containerName: 'web');
      })),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    expect(t1.posts.where((c) => c.path.endsWith('/exec')), hasLength(1));

    container.read(current.notifier).state = t2;
    await tester.pump(const Duration(milliseconds: 100));

    await tester.enterText(find.byType(TextField), 'top');
    await tester.tap(find.byTooltip('Run'));
    await tester.pump(const Duration(milliseconds: 100));

    final created = t2.posts.where((c) => c.path.endsWith('/exec')).toList();
    expect(created, hasLength(1));
    expect(((created.single.body as Map)['Cmd'] as List).last, 'top');
    expect(t1.posts.where((c) => c.path.endsWith('/exec')), hasLength(1));
  });

  testWidgets('Run on the current connection restarts in place', (tester) async {
    final t = freshExecFake();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ExecScreen(containerId: 'abc', containerName: 'web')),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    final before = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(t.posts.where((c) => c.path.endsWith('/exec')), hasLength(1));

    await tester.enterText(find.byType(TextField), 'top');
    await tester.tap(find.byTooltip('Run'));
    await tester.pump(const Duration(milliseconds: 100));

    final created = t.posts.where((c) => c.path.endsWith('/exec')).toList();
    expect(created, hasLength(2));
    expect((created.last.body as Map)['Cmd'], ['/bin/sh', '-c', 'top']);
    expect(t.execChannels.first.closed, isTrue);
    // Still the same session's view: no new controller was built.
    final after = tester.widget<TerminalView>(find.byType(TerminalView));
    expect(after.key, isNotNull);
    expect(after.key, before.key);
    expect(after.terminal, same(before.terminal));
  });

  testWidgets('New session gives the terminal view a new key', (tester) async {
    final t = freshExecFake();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ExecScreen(containerId: 'abc', containerName: 'web')),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    final before = tester.widget<TerminalView>(find.byType(TerminalView)).key;

    await t.lastChannel.controller.close(); // the process exits
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('New session'));
    await tester.pump(const Duration(milliseconds: 100));

    final after = tester.widget<TerminalView>(find.byType(TerminalView)).key;
    expect(after, isNotNull);
    expect(after, isNot(before));
  });

  /// Opens the exec screen on a session the test drives: connected on [t] at first.
  Future<({StubSession stub, SessionState connected})> pumpOnSession(WidgetTester tester, FakeTransport t) async {
    final connected = SessionState(status: SessionStatus.connected, transport: t, sessionId: 1);
    final stub = StubSession(connected);
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWith((ref) => stub)],
      child: const MaterialApp(home: ExecScreen(containerId: 'abc', containerName: 'web')),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    return (stub: stub, connected: connected);
  }

  testWidgets('New session waits for a usable session', (tester) async {
    final t = freshExecFake();
    final (:stub, :connected) = await pumpOnSession(tester, t);
    await t.lastChannel.controller.close(); // the process exits
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.textContaining('Session ended'), findsOneWidget);

    stub.setState(connected.copyWith(status: SessionStatus.reconnecting, attempt: 1));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('New session'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(t.posts.where((c) => c.path.endsWith('/exec')), hasLength(1)); // nothing started on the dead connection
    expect(find.textContaining('Session ended'), findsOneWidget);

    stub.setState(connected);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('New session'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(t.posts.where((c) => c.path.endsWith('/exec')), hasLength(2));
    expect(find.textContaining('Session ended'), findsNothing);
  });

  testWidgets('Run waits for a usable session', (tester) async {
    final t = freshExecFake();
    final (:stub, :connected) = await pumpOnSession(tester, t);
    await tester.enterText(find.byType(TextField), 'top');

    stub.setState(connected.copyWith(status: SessionStatus.reconnecting, attempt: 1));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Run'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(t.posts.where((c) => c.path.endsWith('/exec')), hasLength(1));

    stub.setState(connected);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.byTooltip('Run'));
    await tester.pump(const Duration(milliseconds: 100));
    final created = t.posts.where((c) => c.path.endsWith('/exec')).toList();
    expect(created, hasLength(2));
    expect((created.last.body as Map)['Cmd'], ['/bin/sh', '-c', 'top']);
  });

  testWidgets('Retry waits for a usable session', (tester) async {
    final t = FakeTransport()
      ..onPost(RegExp(r'/exec$'), (_) => http.Response('{"message":"no such container"}', 404));
    final (:stub, :connected) = await pumpOnSession(tester, t);
    expect(find.text('Exec failed'), findsOneWidget);

    stub.setState(connected.copyWith(status: SessionStatus.reconnecting, attempt: 1));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(t.posts.where((c) => c.path.endsWith('/exec')), hasLength(1));

    stub.setState(connected);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Retry'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(t.posts.where((c) => c.path.endsWith('/exec')), hasLength(2));
  });
}
