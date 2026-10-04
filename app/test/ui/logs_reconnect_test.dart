import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/api/timestamps.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/logs_screen.dart';

import '../support/fake_session.dart';

Finder _line(String text) => find.textContaining(text, findRichText: true);

/// Connects a real session through [daemons] (the first one now, the next on
/// every reconnect) and opens the logs screen of container `a`.
Future<ProviderContainer> _openLogs(WidgetTester tester, List<FakeContainerDaemon> daemons) async {
  late ProviderContainer container;
  await tester.pumpWidget(ProviderScope(
    overrides: [
      transportFactoryProvider.overrideWithValue(FakeTransportFactory([for (final d in daemons) d.transport])),
      reconnectPolicyProvider.overrideWithValue(immediatePolicy()),
      lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
      profileStoreProvider.overrideWithValue(InMemoryProfileStore()),
    ],
    child: MaterialApp(
      home: Builder(builder: (ctx) {
        container = ProviderScope.containerOf(ctx);
        return TextButton(
          onPressed: () => Navigator.of(ctx).push(MaterialPageRoute<void>(
              builder: (_) => const LogsScreen(containerId: 'a', containerName: 'web'))),
          child: const Text('open'),
        );
      }),
    ),
  ));
  await container.read(sessionProvider.notifier).connect(const ConnectionProfile(
      id: '1', name: 'A', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://h:1', token: 't')));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

/// Breaks [daemon]'s events stream, so the session reconnects through the next daemon.
Future<void> _dropConnection(WidgetTester tester, FakeContainerDaemon daemon) async {
  daemon.events.addError(const DockerError(DockerErrorKind.network, 'reset'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('every reconnect keeps the lines on screen and resumes after the last one', (tester) async {
    final d1 = FakeContainerDaemon(), d2 = FakeContainerDaemon(), d3 = FakeContainerDaemon();
    final container = await _openLogs(tester, [d1, d2, d3]);

    d1.logs.add(utf8.encode('$firstLogStamp first-line\n'));
    await tester.pumpAndSettle();
    expect(_line('first-line'), findsOneWidget);

    await _dropConnection(tester, d1);
    expect(container.read(transportProvider), same(d2.transport));
    expect(_line('first-line'), findsOneWidget);
    expect(d2.logOpens, hasLength(1));
    expect(d2.logOpens.single.query!['since'], rfc3339ToUnixNanos(firstLogStamp));

    d2.logs.add(utf8.encode('$secondLogStamp second-line\n'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_line('second-line')).dy, greaterThan(tester.getTopLeft(_line('first-line')).dy));

    // Once more: the stream has to move on to the newest transport every time.
    await _dropConnection(tester, d2);
    expect(container.read(transportProvider), same(d3.transport));
    expect(_line('first-line'), findsOneWidget);
    expect(_line('second-line'), findsOneWidget);
    expect(d3.logOpens, hasLength(1));
    expect(d3.logOpens.single.query!['since'], rfc3339ToUnixNanos(secondLogStamp));
    expect(d2.logOpens, hasLength(1));
  });

  testWidgets('a failed inspect refetch after a reconnect keeps the lines', (tester) async {
    final d1 = FakeContainerDaemon(), d2 = FakeContainerDaemon();
    d2.transport.onGet(RegExp(r'/containers/a/json$'), (_) => http.Response('{"message":"daemon busy"}', 500));
    final container = await _openLogs(tester, [d1, d2]);

    d1.logs.add(utf8.encode('$firstLogStamp first-line\n'));
    await tester.pumpAndSettle();
    expect(_line('first-line'), findsOneWidget);

    await _dropConnection(tester, d1);
    expect(container.read(transportProvider), same(d2.transport));
    expect(container.read(containerInspectProvider('a')).hasError, isTrue); // the refetch did fail

    expect(_line('first-line'), findsOneWidget);
    expect(find.byType(MaterialBanner), findsNothing); // no inspect error in place of the body
    expect(d2.logOpens, hasLength(1));
    expect(d2.logOpens.single.query!['since'], rfc3339ToUnixNanos(firstLogStamp));
  });
}
