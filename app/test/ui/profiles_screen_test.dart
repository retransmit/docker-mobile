import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';
import 'package:docker_mobile/src/ui/home_screen.dart';
import 'package:docker_mobile/src/ui/profiles_screen.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';

import '../support/fake_session.dart';
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

/// The list over [store] with a stub session: connects are only recorded.
Future<StubSession> pumpList(WidgetTester tester, ProfileStore store) async {
  final stub = StubSession(const SessionState());
  await tester.pumpWidget(ProviderScope(
    overrides: [
      profileStoreProvider.overrideWithValue(store),
      sessionProvider.overrideWith((ref) => stub),
    ],
    child: const MaterialApp(home: ProfilesScreen()),
  ));
  await tester.pumpAndSettle();
  return stub;
}

/// The list over [store] with a real session whose transports come from [factory].
Future<void> pumpListWithSession(WidgetTester tester, ProfileStore store, FakeTransportFactory factory) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      profileStoreProvider.overrideWithValue(store),
      transportFactoryProvider.overrideWithValue(factory),
      lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
    ],
    child: const MaterialApp(home: ProfilesScreen()),
  ));
  await tester.pumpAndSettle();
}

/// Names the agent profile in the open editor 'home' and taps [button].
Future<void> fillEditorAndTap(WidgetTester tester, String button) async {
  await tester.enterText(find.widgetWithText(TextField, 'Name'), 'home');
  await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '10.0.0.2');
  final finder = find.widgetWithText(button == 'Save' ? OutlinedButton : FilledButton, button);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
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

  testWidgets('the connecting row shows a spinner and the other rows ignore taps', (tester) async {
    final stub = await pumpProfiles(tester, const SessionState(status: SessionStatus.connecting, profile: _a));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      find.descendant(of: find.widgetWithText(Card, 'Alpha'), matching: find.byType(CircularProgressIndicator)),
      findsOneWidget,
    );
    await tester.tap(find.text('Beta'));
    await tester.pump();
    expect(stub.connects, isEmpty);
    expect(stub.disconnects, 0);
  });

  testWidgets('tapping the connecting row cancels the connect', (tester) async {
    final stub = await pumpProfiles(tester, const SessionState(status: SessionStatus.connecting, profile: _a));
    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(stub.disconnects, 1);
    expect(stub.connects, isEmpty);
  });

  testWidgets('tapping the connecting row cancels a real connect, and its late handshake changes nothing', (tester) async {
    final store = InMemoryProfileStore();
    await store.add(_a);
    await store.add(_b);
    final held = Completer<Transport>(); // Alpha's handshake, answered only at the end
    final lateDaemon = FakeDaemon();
    final factory = FakeTransportFactory([
      held.future,
      const DockerError(DockerErrorKind.network, 'Cannot reach the daemon: refused'),
    ]);
    await pumpListWithSession(tester, store, factory);
    final container = ProviderScope.containerOf(tester.element(find.byType(ProfilesScreen)));
    SessionState session() => container.read(sessionProvider);

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    expect(session().status, SessionStatus.connecting);

    await tester.tap(find.text('Alpha')); // the connecting row
    await tester.pump();
    expect(session().status, SessionStatus.disconnected);
    expect(session().error, isNull);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Connecting - tap to cancel'), findsNothing);
    expect(factory.builds, 1);

    // The rows take taps again.
    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    expect(factory.builds, 2);
    expect(
      find.descendant(of: find.widgetWithText(Card, 'Beta'), matching: find.text('Cannot reach the daemon: refused')),
      findsOneWidget,
    );

    // The cancelled handshake answers after all: its transport is closed and nothing else changes.
    held.complete(lateDaemon.transport);
    await tester.pumpAndSettle();
    expect(lateDaemon.transport.closed, isTrue);
    expect(session().status, SessionStatus.disconnected);
    expect(session().profile!.id, 'b');
    expect(session().error!.message, 'Cannot reach the daemon: refused');
    expect(find.byType(HomeScreen, skipOffstage: false), findsNothing);
  });

  for (final outcome in ['answers', 'times out']) {
    testWidgets('a cancelled connect that $outcome late opens nothing', (tester) async {
      final store = InMemoryProfileStore();
      await store.add(_a);
      await store.add(_b);
      final held = Completer<Transport>(); // Alpha's handshake
      final lateDaemon = FakeDaemon();
      final beta = FakeDaemon();
      await pumpListWithSession(tester, store, FakeTransportFactory([held.future, beta.transport]));
      final container = ProviderScope.containerOf(tester.element(find.byType(ProfilesScreen)));

      await tester.tap(find.text('Alpha')); // hangs
      await tester.pump();
      await tester.tap(find.text('Alpha')); // cancelled from its row
      await tester.pump();
      await tester.tap(find.text('Beta')); // connects and opens Home
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.byType(HomeScreen), findsOneWidget);

      // Alpha's attempt finishes only now, while the session is Beta's.
      if (outcome == 'answers') {
        held.complete(lateDaemon.transport);
      } else {
        held.completeError(const DockerError(DockerErrorKind.timeout, 'Timed out waiting for the daemon'));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));

      expect(find.byType(HomeScreen, skipOffstage: false), findsOneWidget);
      final session = container.read(sessionProvider);
      expect(session.status, SessionStatus.connected);
      expect(session.profile!.id, 'b');
      expect(session.transport, same(beta.transport));
      expect(beta.transport.closed, isFalse);
      if (outcome == 'answers') expect(lateDaemon.transport.closed, isTrue);
    });
  }

  testWidgets('the add button and the row menus are off while connecting', (tester) async {
    await pumpProfiles(tester, const SessionState(status: SessionStatus.connecting, profile: _a));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ConnectionScreen), findsNothing);

    for (final menu in [find.byType(PopupMenuButton<String>).first, find.byType(PopupMenuButton<String>).last]) {
      await tester.tap(menu);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    }

    // Settings has nothing to do with the connect and stays live.
    expect(tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.settings)).onPressed, isNotNull);
  });

  testWidgets('the empty-state add button is off while connecting', (tester) async {
    final stub = await pumpList(tester, InMemoryProfileStore());
    stub.setState(const SessionState(status: SessionStatus.connecting, profile: _a));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Add connection'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ConnectionScreen), findsNothing);
  });

  testWidgets('the connecting row says how to cancel', (tester) async {
    final stub = await pumpProfiles(tester, const SessionState(status: SessionStatus.connecting, profile: _a));
    final hint = find.text('Connecting - tap to cancel');
    expect(hint, findsOneWidget);
    expect(find.descendant(of: find.widgetWithText(Card, 'Alpha'), matching: hint), findsOneWidget);
    expect(tester.widget<Text>(hint).style, Theme.of(tester.element(hint)).textTheme.bodySmall);

    stub.setState(const SessionState());
    await tester.pump();
    expect(hint, findsNothing);
  });

  testWidgets('no inline error while the session is reconnecting or failed', (tester) async {
    const error = DockerError(DockerErrorKind.network, 'Cannot reach the daemon: refused');
    final stub = await pumpProfiles(tester, const SessionState(profile: _b, error: error));
    expect(find.text(error.message), findsOneWidget); // a failed connect does show it

    for (final status in [SessionStatus.reconnecting, SessionStatus.failed]) {
      stub.setState(SessionState(status: status, profile: _b, attempt: 1, error: error));
      await tester.pump();
      expect(find.text(error.message), findsNothing, reason: status.name);
      expect(find.text('Beta'), findsOneWidget);
    }
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

  testWidgets('the spinner replaces the avatar without shifting the row text sideways', (tester) async {
    final stub = await pumpProfiles(tester, const SessionState());
    final row = find.widgetWithText(Card, 'Alpha');
    final host = find.descendant(of: row, matching: find.byType(MonoText));
    final titleX = tester.getTopLeft(find.text('Alpha')).dx;
    final hostX = tester.getTopLeft(host).dx;
    final width = tester.getSize(row).width;
    expect(find.descendant(of: row, matching: find.byType(LeadingAvatar)), findsOneWidget);

    stub.setState(const SessionState(status: SessionStatus.connecting, profile: _a));
    await tester.pump();
    expect(find.descendant(of: row, matching: find.byType(LeadingAvatar)), findsNothing);
    expect(find.descendant(of: row, matching: find.byType(CircularProgressIndicator)), findsOneWidget);
    expect(tester.getTopLeft(find.text('Alpha')).dx, titleX);
    expect(tester.getTopLeft(host).dx, hostX);
    expect(tester.getSize(row).width, width);
  });

  testWidgets('Save & Connect from the editor connects on the list', (tester) async {
    final store = InMemoryProfileStore();
    final stub = await pumpList(tester, store);
    await tester.tap(find.widgetWithIcon(FloatingActionButton, Icons.add));
    await tester.pumpAndSettle();
    await fillEditorAndTap(tester, 'Save & Connect');
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionScreen), findsNothing); // back on the list
    expect(find.text('home'), findsOneWidget);
    expect(stub.connects.single, same((await store.list()).single));
  });

  testWidgets('Save & Connect from the empty-state editor connects on the list', (tester) async {
    final store = InMemoryProfileStore();
    final stub = await pumpList(tester, store);
    await tester.tap(find.widgetWithText(FilledButton, 'Add connection'));
    await tester.pumpAndSettle();
    await fillEditorAndTap(tester, 'Save & Connect');
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionScreen), findsNothing);
    expect(stub.connects.single, same((await store.list()).single));
  });

  testWidgets('Edit, then Save & Connect, connects the edited profile on the list', (tester) async {
    final store = InMemoryProfileStore();
    await store.add(_a);
    final stub = await pumpList(tester, store);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await fillEditorAndTap(tester, 'Save & Connect');
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionScreen), findsNothing);
    final stored = await store.list();
    expect(stored.single.name, 'home'); // updated in place, not added
    expect(stored.single.id, 'a');
    expect(stub.connects.single, same(stored.single));
  });

  testWidgets('Save still just closes the editor', (tester) async {
    final store = InMemoryProfileStore();
    final stub = await pumpList(tester, store);
    await tester.tap(find.widgetWithIcon(FloatingActionButton, Icons.add));
    await tester.pumpAndSettle();
    await fillEditorAndTap(tester, 'Save');
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionScreen), findsNothing);
    expect(find.text('home'), findsOneWidget);
    expect(await store.list(), hasLength(1));
    expect(stub.connects, isEmpty);
  });

  testWidgets('a failed Save & Connect shows its error on the list', (tester) async {
    final store = InMemoryProfileStore();
    await pumpListWithSession(
      tester,
      store,
      FakeTransportFactory([const DockerError(DockerErrorKind.network, 'Cannot reach the daemon: refused')]),
    );
    await tester.tap(find.widgetWithIcon(FloatingActionButton, Icons.add));
    await tester.pumpAndSettle();
    await fillEditorAndTap(tester, 'Save & Connect');
    await tester.pumpAndSettle();

    expect(find.byType(ConnectionScreen), findsNothing);
    expect(
      find.descendant(of: find.widgetWithText(Card, 'home'), matching: find.text('Cannot reach the daemon: refused')),
      findsOneWidget,
    );
    expect(find.byType(HomeScreen), findsNothing);
    expect(await store.list(), hasLength(1));
  });

  testWidgets('Save & Connect to a reachable daemon opens Home over the list, not over the editor', (tester) async {
    final d = FakeDaemon();
    await pumpListWithSession(tester, InMemoryProfileStore(), FakeTransportFactory([d.transport]));
    await tester.tap(find.widgetWithIcon(FloatingActionButton, Icons.add));
    await tester.pumpAndSettle();
    await fillEditorAndTap(tester, 'Save & Connect');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 700)); // both route transitions

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.byType(ConnectionScreen, skipOffstage: false), findsNothing);
    expect(find.byType(ProfilesScreen, skipOffstage: false), findsOneWidget);
  });
}
