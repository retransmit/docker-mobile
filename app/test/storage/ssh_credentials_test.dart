import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';

void main() {
  test('key-auth creds round-trip', () {
    const creds = SshCredentials(
      host: 'h', port: 22, username: 'root', authMethod: SshAuthMethod.key,
      privateKeyPem: 'KEY', passphrase: 'pp', pinnedHostKey: 'FP',
    );
    final loaded = SshCredentials.fromJson(creds.toJson());
    expect(loaded.host, 'h');
    expect(loaded.username, 'root');
    expect(loaded.authMethod, SshAuthMethod.key);
    expect(loaded.privateKeyPem, 'KEY');
    expect(loaded.passphrase, 'pp');
    expect(loaded.pinnedHostKey, 'FP');
    expect(loaded.password, isNull);
  });

  test('password-auth creds round-trip with null pin', () {
    const creds = SshCredentials(
        host: 'h', port: 2222, username: 'u', authMethod: SshAuthMethod.password, password: 'pw');
    final loaded = SshCredentials.fromJson(creds.toJson());
    expect(loaded.authMethod, SshAuthMethod.password);
    expect(loaded.password, 'pw');
    expect(loaded.pinnedHostKey, isNull);
    expect(loaded.privateKeyPem, isNull);
  });
}
