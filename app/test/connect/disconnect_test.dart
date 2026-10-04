import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/connect/disconnect.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';

import '../support/fake_session.dart';

void main() {
  testWidgets('disconnect pops to the first route and closes the session', (tester) async {
    final d = FakeDaemon();
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        transportFactoryProvider.overrideWithValue(FakeTransportFactory([d.transport])),
        lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
      ],
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          container = ProviderScope.containerOf(ctx);
          return Scaffold(
            body: Center(child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => Consumer(builder: (c, ref, _) => Scaffold(
                  body: Center(child: ElevatedButton(
                    onPressed: () => disconnect(c, ref),
                    child: const Text('disconnect'),
                  )),
                )),
              )),
              child: const Text('go'),
            )),
          );
        }),
      ),
    ));
    await container.read(sessionProvider.notifier).connect(const ConnectionProfile(
        id: '1', name: 'A', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://h:1', token: 't')));
    expect(container.read(sessionProvider).status, SessionStatus.connected);

    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('disconnect'));
    await tester.pumpAndSettle();

    expect(container.read(sessionProvider).status, SessionStatus.disconnected);
    expect(container.read(transportProvider), isNull);
    expect(d.transport.closed, isTrue);
    expect(find.text('go'), findsOneWidget);
    expect(find.text('disconnect'), findsNothing);
  });
}
