import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/connect/ssh_form.dart';

Widget _wrap(ProfileStore store, {ConnectionProfile? editing}) => ProviderScope(
      overrides: [profileStoreProvider.overrideWithValue(store)],
      child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: SshForm(editing: editing)))),
    );

void main() {
  testWidgets('Save persists an SSH profile (password auth)', (tester) async {
    final store = InMemoryProfileStore();
    await tester.pumpWidget(_wrap(store));
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'box');
    await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '10.0.0.3');
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'root');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.widgetWithText(OutlinedButton, 'Save'));
    await tester.pump();
    final saved = (await store.list()).single;
    expect(saved.kind, ConnectionKind.ssh);
    expect(saved.ssh!.username, 'root');
    expect(saved.ssh!.authMethod, SshAuthMethod.password);
  });

  testWidgets('auth toggle reveals the private-key field', (tester) async {
    await tester.pumpWidget(_wrap(InMemoryProfileStore()));
    await tester.tap(find.text('Key'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Private key (PEM)'), findsOneWidget);
  });
}
