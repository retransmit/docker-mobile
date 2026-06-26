import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';

void main() {
  const creds = SshCredentials(
      host: 'h', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p');

  test('openChannel before connect throws StateError', () {
    final c = RealSshConnection(creds);
    expect(c.openChannel(), throwsA(isA<StateError>()));
  });

  test('sshConnectionFactoryProvider builds a RealSshConnection', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final factory = container.read(sshConnectionFactoryProvider);
    expect(factory(creds), isA<RealSshConnection>());
  });
}
