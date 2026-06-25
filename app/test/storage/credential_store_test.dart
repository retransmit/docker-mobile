import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';

void main() {
  test('save/load round-trips all fields', () async {
    final store = InMemoryCredentialStore();
    const creds = TlsCredentials(
      host: '10.0.0.5', port: 2376,
      clientCertPem: 'CERT', clientKeyPem: 'KEY', caPem: 'CA', insecure: true,
    );
    await store.saveTls(creds);
    final loaded = await store.loadTls();
    expect(loaded, isNotNull);
    expect(loaded!.host, '10.0.0.5');
    expect(loaded.port, 2376);
    expect(loaded.clientCertPem, 'CERT');
    expect(loaded.clientKeyPem, 'KEY');
    expect(loaded.caPem, 'CA');
    expect(loaded.insecure, true);
  });

  test('null CA and default insecure round-trip', () async {
    final store = InMemoryCredentialStore();
    await store.saveTls(const TlsCredentials(host: 'h', port: 2376, clientCertPem: 'c', clientKeyPem: 'k'));
    final loaded = await store.loadTls();
    expect(loaded!.caPem, isNull);
    expect(loaded.insecure, false);
  });

  test('loadTls is null before any save; clearTls empties', () async {
    final store = InMemoryCredentialStore();
    expect(await store.loadTls(), isNull);
    await store.saveTls(const TlsCredentials(host: 'h', port: 1, clientCertPem: 'c', clientKeyPem: 'k'));
    expect(await store.loadTls(), isNotNull);
    await store.clearTls();
    expect(await store.loadTls(), isNull);
  });
}
