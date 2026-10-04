import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';

import '../support/stub_session.dart';

Widget _wrap(ProfileStore store) => ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: ConnectionScreen()),
    );

/// Opens the editor from a host route that keeps whatever the editor returns.
Future<({StubSession stub, List<ConnectionProfile?> results})> _openFromHost(
    WidgetTester tester, ProfileStore store) async {
  final stub = StubSession(const SessionState());
  final results = <ConnectionProfile?>[];
  await tester.pumpWidget(ProviderScope(
    overrides: [
      profileStoreProvider.overrideWithValue(store),
      sessionProvider.overrideWith((ref) => stub),
    ],
    child: MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => results.add(await Navigator.of(context)
                .push<ConnectionProfile>(MaterialPageRoute(builder: (_) => const ConnectionScreen()))),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return (stub: stub, results: results);
}

/// Picks [kind] in the open editor, fills what its form requires and scrolls
/// [button] into view.
Future<Finder> _fill(WidgetTester tester, ConnectionKind kind, {required String button}) async {
  if (kind != ConnectionKind.agent) {
    await tester.tap(find.text(kind == ConnectionKind.tls ? 'TCP+TLS' : 'SSH'));
    await tester.pumpAndSettle();
  }
  await tester.enterText(find.widgetWithText(TextField, 'Name'), 'box');
  await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '10.0.0.2');
  switch (kind) {
    case ConnectionKind.agent:
      break;
    case ConnectionKind.tls:
      await tester.enterText(find.widgetWithText(TextField, 'Client certificate (PEM)'), 'cert');
      await tester.enterText(find.widgetWithText(TextField, 'Client key (PEM)'), 'key');
    case ConnectionKind.ssh:
      await tester.enterText(find.widgetWithText(TextField, 'Username'), 'root');
      await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
  }
  final finder = find.widgetWithText(button == 'Save' ? OutlinedButton : FilledButton, button);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  return finder;
}

/// A store that takes a moment to write, like the platform-backed one, so a
/// second tap can land while the first save is still running.
class _SlowStore extends InMemoryProfileStore {
  @override
  Future<void> add(ConnectionProfile profile) async {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    return super.add(profile);
  }
}

/// A store whose first save fails.
class _FailingOnceStore extends InMemoryProfileStore {
  bool _failed = false;

  @override
  Future<void> add(ConnectionProfile profile) async {
    if (!_failed) {
      _failed = true;
      throw StateError('storage unavailable');
    }
    return super.add(profile);
  }
}

void main() {
  testWidgets('Agent is default; selecting TCP+TLS reveals the cert fields', (tester) async {
    await tester.pumpWidget(_wrap(InMemoryProfileStore()));
    expect(find.widgetWithText(TextField, 'Token'), findsOneWidget);
    await tester.tap(find.text('TCP+TLS'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Client certificate (PEM)'), findsOneWidget);
  });

  testWidgets('Save persists an agent profile with the entered fields', (tester) async {
    final store = InMemoryProfileStore();
    await tester.pumpWidget(_wrap(store));
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'home');
    await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '10.0.0.2');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pump();
    final saved = await store.list();
    expect(saved.single.name, 'home');
    expect(saved.single.kind, ConnectionKind.agent);
    expect(saved.single.agent!.baseUri, 'http://10.0.0.2:8080');
  });

  testWidgets('blank name blocks Save', (tester) async {
    final store = InMemoryProfileStore();
    await tester.pumpWidget(_wrap(store));
    await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '10.0.0.2');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pump();
    expect(find.textContaining('name'), findsOneWidget);
    expect(await store.list(), isEmpty);
  });

  for (final kind in ConnectionKind.values) {
    testWidgets('Save & Connect saves once and returns the profile to the caller (${kind.name})', (tester) async {
      final store = _SlowStore();
      final host = await _openFromHost(tester, store);
      final button = await _fill(tester, kind, button: 'Save & Connect');

      await tester.tap(button);
      await tester.tap(button); // lands while the first save is still running
      await tester.pumpAndSettle();

      final stored = await store.list();
      expect(stored, hasLength(1));
      expect(stored.single.kind, kind);
      expect(find.byType(ConnectionScreen), findsNothing);
      expect(find.text('open'), findsOneWidget); // only the editor was popped
      expect(host.results.single, same(stored.single));
      expect(host.stub.connects, isEmpty); // connecting is the caller's job
    });

    testWidgets('Save saves once and returns nothing to the caller (${kind.name})', (tester) async {
      final store = _SlowStore();
      final host = await _openFromHost(tester, store);
      final button = await _fill(tester, kind, button: 'Save');

      await tester.tap(button);
      await tester.tap(button); // lands while the first save is still running
      await tester.pumpAndSettle();

      expect(await store.list(), hasLength(1));
      expect(find.byType(ConnectionScreen), findsNothing);
      expect(find.text('open'), findsOneWidget);
      expect(host.results.single, isNull);
      expect(host.stub.connects, isEmpty);
    });
  }

  testWidgets('a failed save keeps the editor open and can be tried again', (tester) async {
    final store = _FailingOnceStore();
    final host = await _openFromHost(tester, store);
    final button = await _fill(tester, ConnectionKind.agent, button: 'Save & Connect');

    // The save error is not handled by the form; catch it here so it does not end the test.
    Object? thrown;
    await runZonedGuarded(() => tester.tap(button), (e, _) {
      thrown = e;
    });
    await tester.pumpAndSettle();
    expect(thrown, isStateError);
    expect(find.byType(ConnectionScreen), findsOneWidget);
    expect(await store.list(), isEmpty);
    expect(host.results, isEmpty);

    await tester.tap(button);
    await tester.pumpAndSettle();
    final stored = await store.list();
    expect(stored, hasLength(1));
    expect(find.byType(ConnectionScreen), findsNothing);
    expect(host.results.single, same(stored.single));
  });
}
