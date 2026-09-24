import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/api/models/docker_container.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/containers_screen.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';
import 'package:docker_mobile/src/ui/widgets/skeletons.dart';

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

    expect(find.textContaining('Error:'), findsOneWidget);
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
}
