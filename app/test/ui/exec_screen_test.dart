import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:xterm/xterm.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/ui/exec_screen.dart';

import '../support/fake_transport.dart';

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
}
