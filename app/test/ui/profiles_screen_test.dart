import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';
import 'package:docker_mobile/src/ui/profiles_screen.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';

import '../support/stub_session.dart';

Widget _wrap(ProfileStore store) => ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: ProfilesScreen()),
    );

const _a = ConnectionProfile(id: 'a', name: 'Alpha', kind: ConnectionKind.agent,
    agent: AgentCredentials(baseUri: 'http://a:1', token: 't'));
const _b = ConnectionProfile(id: 'b', name: 'Beta', kind: ConnectionKind.agent,
    agent: AgentCredentials(baseUri: 'http://b:1', token: 't'));

Future<StubSession> pumpProfiles(WidgetTester tester, SessionState s) async {
  final stub = StubSession(s);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sessionProvider.overrideWith((ref) => stub),
      profilesProvider.overrideWith((ref) async => const [_a, _b]),
    ],
    child: const MaterialApp(home: ProfilesScreen()),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return stub;
}

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

  testWidgets('the connecting row shows a spinner and every row ignores taps', (tester) async {
    final stub = await pumpProfiles(tester, const SessionState(status: SessionStatus.connecting, profile: _a));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.descendant(of: find.widgetWithText(Card, 'Alpha'), matching: find.byType(CircularProgressIndicator)),
      findsOneWidget,
    );
    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(stub.connects, isEmpty);
  });

  testWidgets('a failed connect shows its error under that profile only', (tester) async {
    await pumpProfiles(tester, const SessionState(
      profile: _b,
      error: DockerError(DockerErrorKind.network, 'Cannot reach the daemon: refused'),
    ));
    expect(find.text('Cannot reach the daemon: refused'), findsOneWidget);
    expect(
      find.descendant(of: find.widgetWithText(Card, 'Beta'), matching: find.text('Cannot reach the daemon: refused')),
      findsOneWidget,
    );
    final errorText = tester.widget<Text>(find.text('Cannot reach the daemon: refused'));
    final scheme = Theme.of(tester.element(find.text('Beta'))).colorScheme;
    expect(errorText.style!.color, scheme.error);
  });

  testWidgets('tapping a row connects through the session', (tester) async {
    final stub = await pumpProfiles(tester, const SessionState());
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(stub.connects.single.id, 'a');
  });
}
