import 'dart:async';
import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';

void main() {
  const creds = SshCredentials(host: 'h', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p');

  test('connect times out when the socket never opens', () {
    fakeAsync((async) {
      final conn = RealSshConnection(
        creds,
        connector: (_, _, _) => Completer<SSHSocket>().future,
        connectTimeout: const Duration(seconds: 2),
      );
      Object? err;
      conn.connect(verifyHostKey: (_) => true).then((_) {}, onError: (Object e) { err = e; });
      async.elapse(const Duration(seconds: 3));
      expect(err, isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.timeout));
    });
  });

  test('a refused socket surfaces as DockerError.network', () async {
    final conn = RealSshConnection(creds, connector: (_, _, _) async => throw const SocketException('refused'));
    expect(conn.connect(verifyHostKey: (_) => true),
        throwsA(isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.network)));
  });

  test('mapSshError', () {
    expect(mapSshError(TimeoutException('t')).kind, DockerErrorKind.timeout);
    expect(mapSshError(const SocketException('x')).kind, DockerErrorKind.network);
    const passthrough = DockerError(DockerErrorKind.conflict, 'c');
    expect(identical(mapSshError(passthrough), passthrough), isTrue);
    expect(mapSshError(StateError('s')).kind, DockerErrorKind.unknown);
  });
}
