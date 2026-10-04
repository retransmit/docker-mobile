import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/api/models/docker_container.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/transport/timeouts.dart';
import 'package:docker_mobile/src/ui/containers_screen.dart';
import 'package:docker_mobile/src/ui/widgets/error_view.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';
import 'package:docker_mobile/src/ui/widgets/skeletons.dart';

import '../support/fake_session.dart';

void main() {
  testWidgets('renders container names from the provider', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          containersProvider.overrideWith((ref) async => const [
                DockerContainer(id: 'a', names: ['/web'], image: 'nginx', state: 'running', status: 'Up'),
                DockerContainer(id: 'b', names: ['/db'], image: 'postgres', state: 'exited', status: 'Exited'),
              ]),
        ],
        child: const MaterialApp(home: ContainersScreen()),
      ),
    );
    // Let the FutureProvider resolve.
    await tester.pumpAndSettle();

    expect(find.text('/web'), findsOneWidget);
    expect(find.text('/db'), findsOneWidget);
    expect(find.textContaining('nginx'), findsOneWidget);
    // New card-row structure: image as monospace, state as a status pill.
    expect(find.byType(MonoText), findsNWidgets(2));
    expect(find.byType(StatusPill), findsNWidgets(2));
    expect(find.text('running'), findsOneWidget);
    expect(find.text('exited'), findsOneWidget);
  });

  testWidgets('renders an error message when loading fails', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          containersProvider.overrideWith(
            (ref) async => throw DockerError.fromResponse(401, 'unauthorized'),
          ),
        ],
        child: const MaterialApp(home: ContainersScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('Not authorized'), findsOneWidget);
    expect(find.text('unauthorized'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('shows a skeleton while loading', (tester) async {
    final completer = Completer<List<DockerContainer>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          containersProvider.overrideWith((ref) => completer.future),
        ],
        child: const MaterialApp(home: ContainersScreen()),
      ),
    );
    // The shimmer animates forever; pump a fixed duration rather than settling.
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(SkeletonList), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    completer.complete(const []);
    await tester.pumpAndSettle();
  });

  testWidgets('Retry re-runs the provider and shows data on success', (tester) async {
    var calls = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        containersProvider.overrideWith((ref) async {
          calls++;
          if (calls == 1) throw DockerError.fromResponse(500, '{"message":"boom"}');
          return const [DockerContainer(id: 'a', names: ['/web'], image: 'nginx', state: 'running', status: 'Up')];
        }),
      ],
      child: const MaterialApp(home: ContainersScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.byType(ErrorView), findsNothing);
    expect(find.text('/web'), findsOneWidget);
  });

  testWidgets('Retry keeps retrying on repeated failure', (tester) async {
    var calls = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        containersProvider.overrideWith((ref) async {
          calls++;
          throw const DockerError(DockerErrorKind.network, 'down');
        }),
      ],
      child: const MaterialApp(home: ContainersScreen()),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
  });

  testWidgets('Retry shows progress while the refetch is pending', (tester) async {
    var calls = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        containersProvider.overrideWith((ref) async {
          calls++;
          if (calls == 1) throw const DockerError(DockerErrorKind.network, 'down');
          return Completer<List<DockerContainer>>().future;
        }),
      ],
      child: const MaterialApp(home: ContainersScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    await tester.tap(find.text('Retry'));
    // The indicator animates forever, so pump one frame rather than settling.
    await tester.pump();
    expect(calls, 2);
    expect(
      find.descendant(of: find.byType(ErrorView), matching: find.byType(CircularProgressIndicator)),
      findsOneWidget,
    );
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
  });

  testWidgets('a failed pull-to-refresh from the data state shows the error view without an unhandled error',
      (tester) async {
    var calls = 0;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        containersProvider.overrideWith((ref) async {
          calls++;
          if (calls == 1) {
            return const [DockerContainer(id: 'a', names: ['/web'], image: 'nginx', state: 'running', status: 'Up')];
          }
          throw const DockerError(DockerErrorKind.network, 'down');
        }),
      ],
      child: const MaterialApp(home: ContainersScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('/web'), findsOneWidget);

    await tester.fling(find.byType(ListView).first, const Offset(0, 300), 1000);
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorView), findsOneWidget);
  });

  testWidgets('a reconnect keeps the list on screen', (tester) async {
    final d1 = FakeDaemon(), d2 = FakeDaemon();
    d1.transport.onGet(
      RegExp(r'/containers/json$'),
      (_) => http.Response('[{"Id":"a","Names":["/web"],"Image":"nginx","State":"running","Status":"Up"}]', 200),
    );
    d2.transport.hangOn('GET', RegExp(r'/containers/json$'));
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
          return const ContainersScreen();
        }),
      ),
    ));
    await container.read(sessionProvider.notifier).connect(const ConnectionProfile(
        id: '1', name: 'A', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://h:1', token: 't')));
    await tester.pumpAndSettle();
    expect(find.text('/web'), findsOneWidget);

    // The events stream breaks and the session reconnects through the second daemon.
    d1.events.addError(const DockerError(DockerErrorKind.network, 'reset'));
    await tester.pump(const Duration(milliseconds: 50));
    // Long enough for a switch to the skeleton to finish, had one started.
    await tester.pump(const Duration(milliseconds: 400));
    expect(container.read(transportProvider), same(d2.transport));
    expect(d2.transport.calls.where((c) => c.path.endsWith('/containers/json')), hasLength(1)); // refetch in flight
    expect(find.byType(SkeletonList), findsNothing);
    expect(find.text('/web'), findsOneWidget);

    // The refetch never answers: let it time out so that no timer outlives the test.
    await tester.pump(kRequestTimeout);
  });
}
