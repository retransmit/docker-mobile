import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_transport.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';

/// Presents a fixed fingerprint and accepts/rejects via the verifier.
class _FakeSshConnection implements SshConnection {
  final String fingerprint;
  _FakeSshConnection(this.fingerprint);
  @override
  Future<void> connect({required HostKeyVerifier verifyHostKey}) async {
    if (!verifyHostKey(fingerprint)) throw Exception('host key rejected');
  }
  @override
  Future<Duplex> openChannel() async =>
      Duplex(input: const Stream.empty(), add: (_) {}, close: () async {});
  @override
  Future<void> close() async {}
}

Widget _wrap(CredentialStore store, SshConnection Function(SshCredentials) factory) => ProviderScope(
      overrides: [
        credentialStoreProvider.overrideWithValue(store),
        sshConnectionFactoryProvider.overrideWithValue(factory),
      ],
      child: const MaterialApp(home: ConnectionScreen()),
    );

Future<void> _gotoSsh(WidgetTester tester) async {
  await tester.tap(find.text('SSH'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('SSH segment reveals fields; auth toggle swaps key<->password', (tester) async {
    await tester.pumpWidget(_wrap(InMemoryCredentialStore(), (_) => _FakeSshConnection('FP')));
    await _gotoSsh(tester);
    expect(find.widgetWithText(TextField, 'Username'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Password'), findsOneWidget); // password is default
    await tester.tap(find.text('Key'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'Private key (PEM)'), findsOneWidget);
  });

  testWidgets('invalid input blocks connect', (tester) async {
    final store = InMemoryCredentialStore();
    await tester.pumpWidget(_wrap(store, (_) => _FakeSshConnection('FP')));
    final container = ProviderScope.containerOf(tester.element(find.byType(ConnectionScreen)));
    await _gotoSsh(tester);
    // host left empty
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump();
    expect(find.textContaining('valid'), findsOneWidget);
    expect(container.read(transportProvider), isNull);
  });

  testWidgets('firstUse: connects, pins the fingerprint, sets an SshTransport', (tester) async {
    final store = InMemoryCredentialStore();
    await tester.pumpWidget(_wrap(store, (_) => _FakeSshConnection('FP-NEW')));
    final container = ProviderScope.containerOf(tester.element(find.byType(ConnectionScreen)));
    await _gotoSsh(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '10.0.0.9');
    await tester.enterText(find.widgetWithText(TextField, 'Username'), 'root');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'pw');
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(transportProvider), isA<SshTransport>());
    final saved = await store.loadSsh();
    expect(saved!.pinnedHostKey, 'FP-NEW');
    expect(saved.host, '10.0.0.9');
  });

  testWidgets('mismatch: shows the warning dialog; Trust new key re-pins and connects', (tester) async {
    final store = InMemoryCredentialStore();
    // Pre-pin a DIFFERENT fingerprint so the presented one is a mismatch.
    await store.saveSsh(const SshCredentials(
        host: '10.0.0.9', port: 22, username: 'root',
        authMethod: SshAuthMethod.password, password: 'pw', pinnedHostKey: 'FP-OLD'));
    await tester.pumpWidget(_wrap(store, (_) => _FakeSshConnection('FP-NEW')));
    final container = ProviderScope.containerOf(tester.element(find.byType(ConnectionScreen)));
    await _gotoSsh(tester);
    await tester.pumpAndSettle(); // prefill
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('host key'), findsWidgets); // warning dialog
    await tester.tap(find.widgetWithText(TextButton, 'Trust new key'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(container.read(transportProvider), isA<SshTransport>());
    expect((await store.loadSsh())!.pinnedHostKey, 'FP-NEW'); // re-pinned
  });
}
