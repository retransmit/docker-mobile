import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class TlsCredentials {
  final String host;
  final int port;
  final String clientCertPem;
  final String clientKeyPem;
  final String? caPem;
  final bool insecure;

  const TlsCredentials({
    required this.host,
    required this.port,
    required this.clientCertPem,
    required this.clientKeyPem,
    this.caPem,
    this.insecure = false,
  });

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'clientCertPem': clientCertPem,
        'clientKeyPem': clientKeyPem,
        'caPem': caPem,
        'insecure': insecure,
      };

  factory TlsCredentials.fromJson(Map<String, dynamic> json) => TlsCredentials(
        host: json['host'] as String,
        port: (json['port'] as num).toInt(),
        clientCertPem: json['clientCertPem'] as String,
        clientKeyPem: json['clientKeyPem'] as String,
        caPem: json['caPem'] as String?,
        insecure: json['insecure'] as bool? ?? false,
      );
}

class AgentCredentials {
  final String baseUri;
  final String token;
  const AgentCredentials({required this.baseUri, required this.token});
  Map<String, dynamic> toJson() => {'baseUri': baseUri, 'token': token};
  factory AgentCredentials.fromJson(Map<String, dynamic> json) =>
      AgentCredentials(baseUri: json['baseUri'] as String, token: json['token'] as String? ?? '');
}

enum SshAuthMethod { password, key }

class SshCredentials {
  final String host;
  final int port;
  final String username;
  final SshAuthMethod authMethod;
  final String? password;
  final String? privateKeyPem;
  final String? passphrase;
  final String? pinnedHostKey;

  const SshCredentials({
    required this.host,
    required this.port,
    required this.username,
    required this.authMethod,
    this.password,
    this.privateKeyPem,
    this.passphrase,
    this.pinnedHostKey,
  });

  Map<String, dynamic> toJson() => {
        'host': host,
        'port': port,
        'username': username,
        'authMethod': authMethod.name,
        'password': password,
        'privateKeyPem': privateKeyPem,
        'passphrase': passphrase,
        'pinnedHostKey': pinnedHostKey,
      };

  factory SshCredentials.fromJson(Map<String, dynamic> json) => SshCredentials(
        host: json['host'] as String,
        port: (json['port'] as num).toInt(),
        username: json['username'] as String,
        authMethod: SshAuthMethod.values.byName(json['authMethod'] as String),
        password: json['password'] as String?,
        privateKeyPem: json['privateKeyPem'] as String?,
        passphrase: json['passphrase'] as String?,
        pinnedHostKey: json['pinnedHostKey'] as String?,
      );
}

abstract class CredentialStore {
  Future<void> saveTls(TlsCredentials creds);
  Future<TlsCredentials?> loadTls();
  Future<void> clearTls();
  Future<void> saveSsh(SshCredentials creds);
  Future<SshCredentials?> loadSsh();
  Future<void> clearSsh();
}

/// In-memory store for tests (no platform channels).
class InMemoryCredentialStore implements CredentialStore {
  String? _json;
  @override
  Future<void> saveTls(TlsCredentials creds) async => _json = jsonEncode(creds.toJson());
  @override
  Future<TlsCredentials?> loadTls() async =>
      _json == null ? null : TlsCredentials.fromJson(jsonDecode(_json!) as Map<String, dynamic>);
  @override
  Future<void> clearTls() async => _json = null;

  String? _sshJson;
  @override
  Future<void> saveSsh(SshCredentials creds) async => _sshJson = jsonEncode(creds.toJson());
  @override
  Future<SshCredentials?> loadSsh() async =>
      _sshJson == null ? null : SshCredentials.fromJson(jsonDecode(_sshJson!) as Map<String, dynamic>);
  @override
  Future<void> clearSsh() async => _sshJson = null;
}

/// Keychain/Keystore-backed store for the running app.
class SecureCredentialStore implements CredentialStore {
  static const _key = 'tls_last';
  static const _sshKey = 'ssh_last';
  final FlutterSecureStorage _storage;
  SecureCredentialStore([FlutterSecureStorage? storage])
      : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<void> saveTls(TlsCredentials creds) => _storage.write(key: _key, value: jsonEncode(creds.toJson()));

  @override
  Future<TlsCredentials?> loadTls() async {
    final v = await _storage.read(key: _key);
    return v == null ? null : TlsCredentials.fromJson(jsonDecode(v) as Map<String, dynamic>);
  }

  @override
  Future<void> clearTls() => _storage.delete(key: _key);

  @override
  Future<void> saveSsh(SshCredentials creds) => _storage.write(key: _sshKey, value: jsonEncode(creds.toJson()));

  @override
  Future<SshCredentials?> loadSsh() async {
    final v = await _storage.read(key: _sshKey);
    return v == null ? null : SshCredentials.fromJson(jsonDecode(v) as Map<String, dynamic>);
  }

  @override
  Future<void> clearSsh() => _storage.delete(key: _sshKey);
}
