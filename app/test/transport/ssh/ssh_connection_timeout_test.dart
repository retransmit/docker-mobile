import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';

/// Just enough [SSHSocket] to hand to [RealSshConnection]; records release.
class _FakeSocket implements SSHSocket {
  var closed = false;

  @override
  Stream<Uint8List> get stream => throw UnimplementedError();
  @override
  StreamSink<List<int>> get sink => throw UnimplementedError();
  @override
  Future<void> get done => throw UnimplementedError();
  @override
  Future<void> close() async => closed = true;
  @override
  void destroy() => closed = true;
}

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

  test('mapSshError tells a failed login from an aborted one', () {
    final failed = mapSshError(SSHAuthFailError('All authentication methods failed'));
    expect(failed.kind, DockerErrorKind.unauthorized);
    expect(failed.retryable, isFalse);
    final aborted = mapSshError(SSHAuthAbortError('Connection closed before authentication'));
    expect(aborted.kind, DockerErrorKind.network);
    expect(aborted.retryable, isTrue);
  });

  test('mapSshError reports an unreadable private key', () {
    for (final e in [SSHKeyDecodeError('Failed to decode private key'), SSHKeyDecryptError('Invalid passphrase')]) {
      final mapped = mapSshError(e);
      expect(mapped.kind, DockerErrorKind.unauthorized, reason: '$e');
      expect(mapped.message, 'SSH private key could not be read - check the key and passphrase', reason: '$e');
      expect(mapped.retryable, isFalse, reason: '$e');
    }
  });

  test('a client that cannot be built releases the socket', () async {
    final socket = _FakeSocket();
    const keyCreds = SshCredentials(
        host: 'h', port: 22, username: 'u', authMethod: SshAuthMethod.key, privateKeyPem: 'not a key');
    final conn = RealSshConnection(keyCreds, connector: (_, _, _) async => socket);
    await expectLater(
        conn.connect(verifyHostKey: (_) => true),
        throwsA(isA<DockerError>()
            .having((e) => e.kind, 'kind', DockerErrorKind.unauthorized)
            .having((e) => e.message, 'message', 'SSH private key could not be read - check the key and passphrase')
            .having((e) => e.cause, 'cause', isA<FormatException>())));
    expect(socket.closed, isTrue);
  });

  test('a key type dartssh2 cannot parse is reported as unsupported and releases the socket', () async {
    final socket = _FakeSocket();
    // A PKCS#8 `BEGIN PRIVATE KEY` file: valid PEM that SSHKeyPair.fromPem
    // rejects with an UnsupportedError.
    final keyCreds = SshCredentials(
        host: 'h',
        port: 22,
        username: 'u',
        authMethod: SshAuthMethod.key,
        privateKeyPem: File('test/fixtures/client-key.pem').readAsStringSync());
    final conn = RealSshConnection(keyCreds, connector: (_, _, _) async => socket);
    await expectLater(
        conn.connect(verifyHostKey: (_) => true),
        throwsA(isA<DockerError>()
            .having((e) => e.kind, 'kind', DockerErrorKind.unauthorized)
            .having((e) => e.message, 'message',
                'SSH private key type is not supported - use an OpenSSH or PEM RSA/EC key')
            .having((e) => e.cause, 'cause', isA<UnsupportedError>())));
    expect(socket.closed, isTrue);
  });
}
