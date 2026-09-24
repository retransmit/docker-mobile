import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../api/docker_error.dart';
import '../../storage/credential_store.dart';
import '../timeouts.dart';
import 'stream_http.dart';

/// A raw bidirectional byte stream to the remote dockerd socket.
class Duplex {
  final Stream<List<int>> input;
  final void Function(List<int>) add;
  final Future<void> Function() close;
  Duplex({required this.input, required this.add, required this.close});
}

/// Called with the presented host-key fingerprint; returns true to trust it.
typedef HostKeyVerifier = bool Function(String presentedFingerprint);

/// Opens an SSH session running `docker system dial-stdio` and exposes its
/// stdio as a [Duplex]. The live dartssh2 calls are not unit-tested (manual
/// smoke); keep this thin.
class SshDaemonConnection {
  static Future<Duplex> open(SshCredentials creds, {required HostKeyVerifier verifyHostKey}) async {
    final socket = await SSHSocket.connect(creds.host, creds.port);
    final client = SSHClient(
      socket,
      username: creds.username,
      onPasswordRequest:
          creds.authMethod == SshAuthMethod.password ? () => creds.password ?? '' : null,
      identities: creds.authMethod == SshAuthMethod.key && creds.privateKeyPem != null
          ? SSHKeyPair.fromPem(creds.privateKeyPem!, creds.passphrase)
          : null,
      // dartssh2 2.18.0 has already SHA-256-hashed the presented host key and
      // hands us `utf8('SHA256:' + base64-no-pad(sha256(hostkey)))`. Strip the
      // 'SHA256:' prefix so the verdict runs over the same fingerprint string
      // that `fingerprintSha256` (host_key.dart) produces for pinning.
      onVerifyHostKey: (type, fingerprint) =>
          verifyHostKey(utf8.decode(fingerprint).replaceFirst('SHA256:', '')),
    );
    final session = await client.execute('docker system dial-stdio');
    return Duplex(
      input: session.stdout,
      add: (bytes) => session.stdin.add(Uint8List.fromList(bytes)),
      close: () async {
        session.close();
        client.close();
      },
    );
  }
}

/// Issues a GET over an already-open daemon [conn] and buffers the response.
Future<({int statusCode, Map<String, String> headers, List<int> body})> dockerGet(
    Duplex conn, String path) async {
  writeHttpRequest(conn.add, method: 'GET', path: path);
  return readBufferedResponse(conn.input);
}

/// Proves reach: connect over SSH, dial-stdio, GET /version. Manual-smoke only.
Future<String> sshDaemonVersion(SshCredentials creds, {required HostKeyVerifier verifyHostKey}) async {
  final conn = await SshDaemonConnection.open(creds, verifyHostKey: verifyHostKey);
  try {
    final resp = await dockerGet(conn, '/version');
    return utf8.decode(resp.body);
  } finally {
    await conn.close();
  }
}

/// A live SSH connection to a Docker host: one shared client, a cheap
/// `dial-stdio` channel per request.
abstract class SshConnection {
  Future<void> connect({required HostKeyVerifier verifyHostKey});
  Future<Duplex> openChannel();
  Future<void> close();
}

String _stripSha256Prefix(String fp) => fp.startsWith('SHA256:') ? fp.substring(7) : fp;

/// Opens the TCP socket to an SSH server, giving up after `timeout`.
typedef SshSocketConnector = Future<SSHSocket> Function(String host, int port, Duration timeout);

Future<SSHSocket> _defaultConnector(String host, int port, Duration timeout) =>
    SSHSocket.connect(host, port, timeout: timeout);

/// A private key that fails to parse or decrypt: not retryable until the user
/// fixes the key or passphrase.
DockerError _unreadableKey(Object cause) => DockerError(
    DockerErrorKind.unauthorized, 'SSH private key could not be read - check the key and passphrase',
    cause: cause);

/// Maps SSH-layer failures to [DockerError]. Public for tests.
DockerError mapSshError(Object e) {
  if (e is DockerError) return e;
  if (e is TimeoutException) return DockerError(DockerErrorKind.timeout, 'SSH connection timed out', cause: e);
  if (e is SSHAuthFailError) return DockerError(DockerErrorKind.unauthorized, 'SSH authentication failed', cause: e);
  if (e is SSHAuthAbortError) return DockerError(DockerErrorKind.network, 'SSH connection aborted during authentication', cause: e);
  // Fallback for any other SSHAuthError implementer.
  if (e is SSHAuthError) return DockerError(DockerErrorKind.unauthorized, 'SSH authentication failed', cause: e);
  // dartssh2 2.18 surfaces a rejected host key as an SSHAuthAbortError (above);
  // the launcher's verifier flag is the source of truth for a mismatch.
  if (e is SSHHostkeyError) return DockerError(DockerErrorKind.unauthorized, 'SSH host key rejected', cause: e);
  // Also covers SSHKeyDecryptError (a wrong or missing passphrase), which extends it.
  if (e is SSHKeyDecodeError) return _unreadableKey(e);
  if (e is SSHError) return DockerError(DockerErrorKind.network, 'SSH error: $e', cause: e);
  return DockerError.fromException(e);
}

class RealSshConnection implements SshConnection {
  final SshCredentials creds;
  final SshSocketConnector _connector;
  final Duration _connectTimeout;
  SSHClient? _client;

  RealSshConnection(this.creds, {SshSocketConnector? connector, Duration connectTimeout = kConnectTimeout})
      : _connector = connector ?? _defaultConnector,
        // ignore: prefer_initializing_formals
        _connectTimeout = connectTimeout;

  @override
  Future<void> connect({required HostKeyVerifier verifyHostKey}) async {
    final SSHSocket socket;
    try {
      socket = await _connector(creds.host, creds.port, _connectTimeout).timeout(_connectTimeout);
    } catch (e) {
      throw mapSshError(e);
    }
    final SSHClient client;
    try {
      client = SSHClient(
        socket,
        username: creds.username,
        onPasswordRequest:
            creds.authMethod == SshAuthMethod.password ? () => creds.password ?? '' : null,
        identities: creds.authMethod == SshAuthMethod.key && creds.privateKeyPem != null
            ? SSHKeyPair.fromPem(creds.privateKeyPem!, creds.passphrase)
            : null,
        // dartssh2 hands a precomputed utf8('SHA256:'+base64NoPad(sha256(hostkey)));
        // stripping the prefix yields exactly fingerprintSha256()'s output.
        onVerifyHostKey: (type, fingerprint) =>
            verifyHostKey(_stripSha256Prefix(String.fromCharCodes(fingerprint))),
      );
    } catch (e, st) {
      // A bad key or passphrase throws here (SSHKeyPair.fromPem): release the
      // already-connected socket rather than leak it. Text that is not PEM at
      // all fails as a FormatException, which is the same unreadable key.
      socket.destroy();
      Error.throwWithStackTrace(e is FormatException ? _unreadableKey(e) : mapSshError(e), st);
    }
    _client = client;
    try {
      await client.authenticated.timeout(_connectTimeout); // handshake + host-key callback + auth
    } catch (e) {
      // Auth / host-key-mismatch / post-handshake failure: reclaim the socket
      // rather than leaving a live client (and a channel to a suspicious host).
      client.close();
      _client = null;
      throw mapSshError(e);
    }
  }

  @override
  Future<Duplex> openChannel() async {
    final client = _client;
    if (client == null) throw StateError('SSH not connected');
    final session = await client.execute('docker system dial-stdio');
    return Duplex(
      input: session.stdout,
      add: (bytes) => session.stdin.add(Uint8List.fromList(bytes)),
      close: () async => session.close(),
    );
  }

  @override
  Future<void> close() async => _client?.close();
}
