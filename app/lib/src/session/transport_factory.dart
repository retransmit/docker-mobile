import '../api/docker_error.dart';
import '../storage/credential_store.dart';
import '../storage/profile_store.dart';
import '../transport/connection_config.dart';
import '../transport/ssh/host_key.dart';
import '../transport/ssh/ssh_connection.dart';
import '../transport/ssh/ssh_transport.dart';
import '../transport/tls_security.dart';
import '../transport/transport.dart';

/// The SSH server presented a host key that differs from the pinned one.
class HostKeyMismatchException implements Exception {
  final String presentedFingerprint;
  const HostKeyMismatchException(this.presentedFingerprint);

  @override
  String toString() => 'Host key changed (presented $presentedFingerprint)';
}

/// A freshly built transport plus, for SSH, the host key the server showed.
class BuiltTransport {
  final Transport transport;
  final String? presentedHostKey;
  const BuiltTransport(this.transport, {this.presentedHostKey});
}

/// Builds a live [Transport] from a saved profile. No UI: the caller decides
/// what to do with a host-key mismatch.
class TransportFactory {
  final SshConnection Function(SshCredentials) _sshConnectionFactory;

  TransportFactory({required SshConnection Function(SshCredentials) sshConnectionFactory})
      // ignore: prefer_initializing_formals
      : _sshConnectionFactory = sshConnectionFactory;

  /// [pinOverride] replaces the stored SSH host-key pin (used after the user
  /// trusts a changed key).
  Future<BuiltTransport> build(ConnectionProfile profile, {String? pinOverride}) async {
    switch (profile.kind) {
      case ConnectionKind.agent:
        final a = profile.agent!;
        final Uri uri;
        try {
          uri = Uri.parse(a.baseUri);
        } on FormatException catch (e) {
          throw DockerError(DockerErrorKind.badRequest, 'Invalid agent address: ${e.message}', cause: e);
        }
        return BuiltTransport(AgentConnectionConfig(baseUri: uri, token: a.token).build());
      case ConnectionKind.tls:
        final t = profile.tls!;
        try {
          return BuiltTransport(TlsConnectionConfig(
            host: t.host,
            port: t.port,
            clientCertPem: t.clientCertPem,
            clientKeyPem: t.clientKeyPem,
            caPem: t.caPem,
            insecure: t.insecure,
          ).build());
        } on TlsConfigException catch (e) {
          throw DockerError(DockerErrorKind.badRequest, 'Invalid certificate: ${e.message}', cause: e);
        }
      case ConnectionKind.ssh:
        return _buildSsh(profile.ssh!, pinOverride);
    }
  }

  Future<BuiltTransport> _buildSsh(SshCredentials ssh, String? pinOverride) async {
    final pin = pinOverride ?? ssh.pinnedHostKey;
    final conn = _sshConnectionFactory(SshCredentials(
      host: ssh.host,
      port: ssh.port,
      username: ssh.username,
      authMethod: ssh.authMethod,
      password: ssh.password,
      privateKeyPem: ssh.privateKeyPem,
      passphrase: ssh.passphrase,
      pinnedHostKey: pin,
    ));
    String? presented;
    var mismatch = false;
    bool verifier(String fingerprint) {
      presented = fingerprint;
      if (verifyHostKey(pin, fingerprint) == HostKeyVerdict.mismatch) {
        mismatch = true;
        return false;
      }
      return true;
    }

    try {
      await conn.connect(verifyHostKey: verifier);
    } catch (e, st) {
      await conn.close();
      final shown = presented;
      if (mismatch && shown != null) throw HostKeyMismatchException(shown);
      Error.throwWithStackTrace(DockerError.wrap(e), st);
    }
    return BuiltTransport(
      SshTransport(openDuplex: conn.openChannel, onClose: conn.close),
      presentedHostKey: presented,
    );
  }
}
