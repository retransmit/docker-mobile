import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/session/transport_factory.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/transport/agent_transport.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_transport.dart';
import 'package:docker_mobile/src/transport/tls_transport.dart';

import '../support/fake_session.dart';

ConnectionProfile sshProfile({String? pin}) => ConnectionProfile(
      id: 's', name: 'S', kind: ConnectionKind.ssh,
      ssh: SshCredentials(host: 'h', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p', pinnedHostKey: pin),
    );

void main() {
  test('agent profiles build an AgentTransport', () async {
    final f = TransportFactory(sshConnectionFactory: (_) => FakeSshConnection('FP'));
    final b = await f.build(const ConnectionProfile(id: 'a', name: 'A', kind: ConnectionKind.agent,
        agent: AgentCredentials(baseUri: 'http://10.0.0.5:8080', token: 't')));
    expect(b.transport, isA<AgentTransport>());
    expect(b.presentedHostKey, isNull);
    await b.transport.close();
  });

  test('a malformed agent address is a badRequest DockerError', () async {
    final f = TransportFactory(sshConnectionFactory: (_) => FakeSshConnection('FP'));
    await expectLater(
      f.build(const ConnectionProfile(id: 'a', name: 'A', kind: ConnectionKind.agent,
          agent: AgentCredentials(baseUri: 'http://[::1', token: 't'))),
      throwsA(isA<DockerError>()
          .having((e) => e.kind, 'kind', DockerErrorKind.badRequest)
          .having((e) => e.message, 'message', startsWith('Invalid agent address'))),
    );
  });

  test('TLS profiles build a TlsTransport from valid PEMs', () async {
    final cert = File('test/fixtures/client-cert.pem').readAsStringSync();
    final key = File('test/fixtures/client-key.pem').readAsStringSync();
    final f = TransportFactory(sshConnectionFactory: (_) => FakeSshConnection('FP'));
    final b = await f.build(ConnectionProfile(id: 't', name: 'T', kind: ConnectionKind.tls,
        tls: TlsCredentials(host: 'h', port: 2376, clientCertPem: cert, clientKeyPem: key)));
    expect(b.transport, isA<TlsTransport>());
    await b.transport.close();
  });

  test('a bad certificate is a badRequest DockerError', () async {
    final f = TransportFactory(sshConnectionFactory: (_) => FakeSshConnection('FP'));
    await expectLater(
      f.build(const ConnectionProfile(id: 't', name: 'T', kind: ConnectionKind.tls,
          tls: TlsCredentials(host: 'h', port: 2376, clientCertPem: 'nope', clientKeyPem: 'nope'))),
      throwsA(isA<DockerError>()
          .having((e) => e.kind, 'kind', DockerErrorKind.badRequest)
          .having((e) => e.message, 'message', startsWith('Invalid certificate'))),
    );
  });

  test('SSH first use builds an SshTransport and reports the presented key', () async {
    final f = TransportFactory(sshConnectionFactory: (_) => FakeSshConnection('FP-NEW'));
    final b = await f.build(sshProfile());
    expect(b.transport, isA<SshTransport>());
    expect(b.presentedHostKey, 'FP-NEW');
  });

  test('SSH with a matching pin connects', () async {
    final f = TransportFactory(sshConnectionFactory: (_) => FakeSshConnection('FP'));
    expect((await f.build(sshProfile(pin: 'FP'))).transport, isA<SshTransport>());
  });

  test('SSH host-key mismatch throws HostKeyMismatchException and closes the connection', () async {
    final conn = FakeSshConnection('FP-NEW');
    final f = TransportFactory(sshConnectionFactory: (_) => conn);
    await expectLater(
      f.build(sshProfile(pin: 'FP-OLD')),
      throwsA(isA<HostKeyMismatchException>().having((e) => e.presentedFingerprint, 'presented', 'FP-NEW')),
    );
    expect(conn.closed, isTrue);
  });

  test('pinOverride replaces the stored pin', () async {
    SshCredentials? seen;
    final f = TransportFactory(sshConnectionFactory: (c) {
      seen = c;
      return FakeSshConnection('FP-NEW');
    });
    await f.build(sshProfile(pin: 'FP-OLD'), pinOverride: 'FP-NEW');
    expect(seen!.pinnedHostKey, 'FP-NEW');
  });

  test('other SSH failures surface as DockerError and close the connection', () async {
    final conn = FakeSshConnection('FP',
        connectError: const DockerError(DockerErrorKind.unauthorized, 'SSH authentication failed'));
    final f = TransportFactory(sshConnectionFactory: (_) => conn);
    await expectLater(
      f.build(sshProfile(pin: 'FP')),
      throwsA(isA<DockerError>().having((e) => e.kind, 'kind', DockerErrorKind.unauthorized)),
    );
    expect(conn.closed, isTrue);
  });
}
