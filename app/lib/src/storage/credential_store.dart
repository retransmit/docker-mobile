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

abstract class CredentialStore {
  Future<void> saveTls(TlsCredentials creds);
  Future<TlsCredentials?> loadTls();
  Future<void> clearTls();
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
}

/// Keychain/Keystore-backed store for the running app.
class SecureCredentialStore implements CredentialStore {
  static const _key = 'tls_last';
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
}
