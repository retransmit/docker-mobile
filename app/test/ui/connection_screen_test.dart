import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/transport/tls_transport.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';

Widget _wrap(CredentialStore store) => ProviderScope(
      overrides: [credentialStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: ConnectionScreen()),
    );

void main() {
  final cert = File('test/fixtures/client-cert.pem').readAsStringSync();
  final key = File('test/fixtures/client-key.pem').readAsStringSync();

  testWidgets('selecting TCP+TLS reveals the PEM fields', (tester) async {
    await tester.pumpWidget(_wrap(InMemoryCredentialStore()));
    expect(find.text('Client certificate (PEM)'), findsNothing); // agent tab first
    await tester.tap(find.text('TCP+TLS'));
    await tester.pumpAndSettle();
    expect(find.text('Client certificate (PEM)'), findsOneWidget);
    expect(find.text('Client key (PEM)'), findsOneWidget);
  });

  testWidgets('invalid host blocks connect', (tester) async {
    final store = InMemoryCredentialStore();
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [credentialStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: ConnectionScreen()),
    ));
    container = ProviderScope.containerOf(tester.element(find.byType(ConnectionScreen)));
    await tester.tap(find.text('TCP+TLS'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Client certificate (PEM)'), cert);
    await tester.enterText(find.widgetWithText(TextField, 'Client key (PEM)'), key);
    // host left empty
    final connect = find.widgetWithText(FilledButton, 'Connect');
    await tester.ensureVisible(connect); // button sits below the test viewport
    await tester.tap(connect);
    await tester.pump();
    expect(find.textContaining('valid host'), findsOneWidget);
    expect(container.read(transportProvider), isNull);
  });

  testWidgets('valid TLS submit sets a TlsTransport and saves creds', (tester) async {
    final store = InMemoryCredentialStore();
    await tester.pumpWidget(_wrap(store));
    final container = ProviderScope.containerOf(tester.element(find.byType(ConnectionScreen)));
    await tester.tap(find.text('TCP+TLS'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Host / IP'), '127.0.0.1');
    await tester.enterText(find.widgetWithText(TextField, 'Client certificate (PEM)'), cert);
    await tester.enterText(find.widgetWithText(TextField, 'Client key (PEM)'), key);
    final connect = find.widgetWithText(FilledButton, 'Connect');
    await tester.ensureVisible(connect); // button sits below the test viewport
    await tester.tap(connect);
    await tester.pump(); // one frame; do NOT settle (HomeScreen would hit the network)

    expect(container.read(transportProvider), isA<TlsTransport>());
    final saved = await store.loadTls();
    expect(saved, isNotNull);
    expect(saved!.host, '127.0.0.1');
    expect(saved.clientCertPem, cert);
  });

  testWidgets('prefills the form from stored credentials', (tester) async {
    final store = InMemoryCredentialStore();
    await store.saveTls(TlsCredentials(host: '192.168.1.50', port: 2376, clientCertPem: cert, clientKeyPem: key));
    await tester.pumpWidget(_wrap(store));
    await tester.tap(find.text('TCP+TLS'));
    await tester.pumpAndSettle(); // lets initState's async prefill complete
    expect(find.text('192.168.1.50'), findsOneWidget);
  });
}
