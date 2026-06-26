import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import '../../storage/credential_store.dart';
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

class RealSshConnection implements SshConnection {
  final SshCredentials creds;
  SSHClient? _client;
  RealSshConnection(this.creds);

  @override
  Future<void> connect({required HostKeyVerifier verifyHostKey}) async {
    final socket = await SSHSocket.connect(creds.host, creds.port);
    final client = SSHClient(
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
    _client = client;
    await client.authenticated; // forces handshake + host-key callback + auth
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
