import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';
import 'package:docker_mobile/src/ui/profiles_screen.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';

Widget _wrap(ProfileStore store) => ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: ProfilesScreen()),
    );

void main() {
  testWidgets('empty state, then renders saved profiles', (tester) async {
    final store = InMemoryProfileStore();
    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();
    expect(find.text('No connections'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add connection'), findsOneWidget);

    await store.add(const ConnectionProfile(id: '1', name: 'prod', kind: ConnectionKind.ssh,
        ssh: SshCredentials(host: 'srv', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p')));
    // a fresh pump container picks up the seeded store (pump an empty tree
    // first so the old ProviderScope/container is disposed and recreated)
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();
    expect(find.text('prod'), findsOneWidget);
    expect(find.textContaining('srv'), findsOneWidget);
    // New card-row structure: kind as a chip, host as monospace.
    expect(find.byType(MetaChip), findsOneWidget);
    expect(find.text('ssh'), findsOneWidget);
    expect(find.byType(MonoText), findsOneWidget);
  });

  testWidgets('+ opens the editor', (tester) async {
    await tester.pumpWidget(_wrap(InMemoryProfileStore()));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithIcon(FloatingActionButton, Icons.add));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionScreen), findsOneWidget);
  });

  testWidgets('Delete removes a profile', (tester) async {
    final store = InMemoryProfileStore();
    await store.add(const ConnectionProfile(id: '1', name: 'gone', kind: ConnectionKind.agent,
        agent: AgentCredentials(baseUri: 'http://h:8080', token: 't')));
    await tester.pumpWidget(_wrap(store));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(await store.list(), isEmpty);
    expect(find.text('gone'), findsNothing);
  });
}
