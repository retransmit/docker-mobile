import 'dart:async';
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
import '../support/fake_transport.dart';

/// A daemon with container `a`, a TTY (so its log bytes are sent unframed).
/// Every logs open gets a stream that stays open; the test writes to [logs].
class _Daemon extends FakeDaemon {
  _Daemon() {
    transport
      ..onGet(RegExp(r'/containers/a/json$'), (_) => http.Response(
            '{"Id":"a","Name":"/web","Config":{"Image":"nginx","Tty":true},"State":{"Status":"running"}}',
            200,
          ))
      ..onStream(RegExp(r'/containers/a/logs$'), (_) => (logs = StreamController<List<int>>()).stream);
  }

  /// The most recently opened logs stream.
  late StreamController<List<int>> logs;

  List<RecordedCall> get logOpens =>
      transport.calls.where((c) => c.method == 'STREAM' && c.path.endsWith('/containers/a/logs')).toList();
}

const _first = '2026-01-02T03:04:05.000000001Z';
const _second = '2026-01-02T03:04:05.000000002Z';

Finder _line(String text) => find.textContaining(text, findRichText: true);

void main() {
  testWidgets('a reconnect keeps the lines on screen and resumes after the last one', (tester) async {
    final d1 = _Daemon(), d2 = _Daemon();
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        transportFactoryProvider.overrideWithValue(FakeTransportFactory([d1.transport, d2.transport])),
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

    d1.logs.add(utf8.encode('$_first first-line\n'));
    await tester.pumpAndSettle();
    expect(_line('first-line'), findsOneWidget);

    d1.events.addError(const DockerError(DockerErrorKind.network, 'reset'));
    await tester.pumpAndSettle(); // the session reconnects through the second daemon
    expect(container.read(transportProvider), same(d2.transport));

    expect(_line('first-line'), findsOneWidget);
    expect(d2.logOpens, hasLength(1));
    expect(d2.logOpens.single.query!['since'], rfc3339ToUnixNanos(_first));

    d2.logs.add(utf8.encode('$_second second-line\n'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(_line('second-line')).dy, greaterThan(tester.getTopLeft(_line('first-line')).dy));
  });
}
