import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';

Widget _wrap(ProfileStore store) => ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: ConnectionScreen()),
    );

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
}
