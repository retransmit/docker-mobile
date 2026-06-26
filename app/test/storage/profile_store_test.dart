import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';

ConnectionProfile _agent(String id, String name) => ConnectionProfile(
    id: id, name: name, kind: ConnectionKind.agent,
    agent: const AgentCredentials(baseUri: 'http://h:8080', token: 't'));

void main() {
  test('agent/tls/ssh profiles round-trip via JSON', () {
    final agent = _agent('1', 'A');
    expect(ConnectionProfile.fromJson(agent.toJson()).agent!.baseUri, 'http://h:8080');

    final tls = ConnectionProfile(id: '2', name: 'T', kind: ConnectionKind.tls,
        tls: const TlsCredentials(host: 'th', port: 2376, clientCertPem: 'c', clientKeyPem: 'k'));
    final tls2 = ConnectionProfile.fromJson(tls.toJson());
    expect(tls2.kind, ConnectionKind.tls);
    expect(tls2.tls!.host, 'th');
    expect(tls2.agent, isNull);

    final ssh = ConnectionProfile(id: '3', name: 'S', kind: ConnectionKind.ssh,
        ssh: const SshCredentials(host: 'sh', port: 22, username: 'u', authMethod: SshAuthMethod.password, password: 'p', pinnedHostKey: 'FP'));
    final ssh2 = ConnectionProfile.fromJson(ssh.toJson());
    expect(ssh2.ssh!.pinnedHostKey, 'FP');
    expect(ssh2.host, 'sh');
  });

  test('host getter resolves per kind', () {
    expect(_agent('1', 'A').host, 'h');
  });

  test('store add/list/update/delete', () async {
    final store = InMemoryProfileStore();
    await store.add(_agent('1', 'A'));
    await store.add(_agent('2', 'B'));
    expect((await store.list()).length, 2);

    await store.update(_agent('1', 'A2'));
    expect((await store.list()).firstWhere((p) => p.id == '1').name, 'A2');

    await store.delete('2');
    final ids = (await store.list()).map((p) => p.id).toList();
    expect(ids, ['1']);
  });
}
