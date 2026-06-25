import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';

void main() {
  test('key-auth creds round-trip', () async {
    final store = InMemoryCredentialStore();
    const creds = SshCredentials(
      host: 'h', port: 22, username: 'root', authMethod: SshAuthMethod.key,
      privateKeyPem: 'KEY', passphrase: 'pp', pinnedHostKey: 'FP',
    );
    await store.saveSsh(creds);
    final loaded = await store.loadSsh();
    expect(loaded!.host, 'h');
    expect(loaded.username, 'root');
    expect(loaded.authMethod, SshAuthMethod.key);
    expect(loaded.privateKeyPem, 'KEY');
    expect(loaded.passphrase, 'pp');
    expect(loaded.pinnedHostKey, 'FP');
    expect(loaded.password, isNull);
  });

  test('password-auth creds round-trip with null pin', () async {
    final store = InMemoryCredentialStore();
    await store.saveSsh(const SshCredentials(
      host: 'h', port: 2222, username: 'u', authMethod: SshAuthMethod.password, password: 'pw'));
    final loaded = await store.loadSsh();
    expect(loaded!.authMethod, SshAuthMethod.password);
    expect(loaded.password, 'pw');
    expect(loaded.pinnedHostKey, isNull);
    expect(loaded.privateKeyPem, isNull);
  });

  test('clearSsh empties only the ssh slot; tls slot is independent', () async {
    final store = InMemoryCredentialStore();
    await store.saveTls(const TlsCredentials(host: 't', port: 2376, clientCertPem: 'c', clientKeyPem: 'k'));
    await store.saveSsh(const SshCredentials(host: 'h', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'pw'));
    await store.clearSsh();
    expect(await store.loadSsh(), isNull);
    expect(await store.loadTls(), isNotNull); // unaffected
  });
}
