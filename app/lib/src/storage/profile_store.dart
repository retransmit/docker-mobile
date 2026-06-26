import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'credential_store.dart';

enum ConnectionKind { agent, tls, ssh }

/// A unique id for a new profile (UI-layer; never compared for value in tests).
String newProfileId() => DateTime.now().microsecondsSinceEpoch.toString();

class ConnectionProfile {
  final String id;
  final String name;
  final ConnectionKind kind;
  final AgentCredentials? agent;
  final TlsCredentials? tls;
  final SshCredentials? ssh;

  const ConnectionProfile({
    required this.id,
    required this.name,
    required this.kind,
    this.agent,
    this.tls,
    this.ssh,
  });

  String get host => switch (kind) {
        ConnectionKind.agent => Uri.tryParse(agent?.baseUri ?? '')?.host ?? '',
        ConnectionKind.tls => tls?.host ?? '',
        ConnectionKind.ssh => ssh?.host ?? '',
      };

  ConnectionProfile copyWith({String? name, AgentCredentials? agent, TlsCredentials? tls, SshCredentials? ssh}) =>
      ConnectionProfile(
        id: id,
        name: name ?? this.name,
        kind: kind,
        agent: agent ?? this.agent,
        tls: tls ?? this.tls,
        ssh: ssh ?? this.ssh,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'agent': agent?.toJson(),
        'tls': tls?.toJson(),
        'ssh': ssh?.toJson(),
      };

  factory ConnectionProfile.fromJson(Map<String, dynamic> json) => ConnectionProfile(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: ConnectionKind.values.byName(json['kind'] as String),
        agent: json['agent'] == null ? null : AgentCredentials.fromJson(json['agent'] as Map<String, dynamic>),
        tls: json['tls'] == null ? null : TlsCredentials.fromJson(json['tls'] as Map<String, dynamic>),
        ssh: json['ssh'] == null ? null : SshCredentials.fromJson(json['ssh'] as Map<String, dynamic>),
      );
}

abstract class ProfileStore {
  Future<List<ConnectionProfile>> list();
  Future<void> add(ConnectionProfile profile);
  Future<void> update(ConnectionProfile profile);
  Future<void> delete(String id);
}

class InMemoryProfileStore implements ProfileStore {
  final List<ConnectionProfile> _profiles = [];
  @override
  Future<List<ConnectionProfile>> list() async => List.unmodifiable(_profiles);
  @override
  Future<void> add(ConnectionProfile profile) async => _profiles.add(profile);
  @override
  Future<void> update(ConnectionProfile profile) async {
    final i = _profiles.indexWhere((p) => p.id == profile.id);
    if (i >= 0) _profiles[i] = profile;
  }
  @override
  Future<void> delete(String id) async => _profiles.removeWhere((p) => p.id == id);
}

class SecureProfileStore implements ProfileStore {
  static const _key = 'profiles';
  final FlutterSecureStorage _storage;
  SecureProfileStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  Future<List<ConnectionProfile>> _read() async {
    final v = await _storage.read(key: _key);
    if (v == null) return [];
    return (jsonDecode(v) as List).map((e) => ConnectionProfile.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> _write(List<ConnectionProfile> ps) =>
      _storage.write(key: _key, value: jsonEncode(ps.map((p) => p.toJson()).toList()));

  @override
  Future<List<ConnectionProfile>> list() => _read();
  @override
  Future<void> add(ConnectionProfile profile) async {
    final ps = await _read();
    ps.add(profile);
    await _write(ps);
  }
  @override
  Future<void> update(ConnectionProfile profile) async {
    final ps = await _read();
    final i = ps.indexWhere((p) => p.id == profile.id);
    if (i >= 0) ps[i] = profile;
    await _write(ps);
  }
  @override
  Future<void> delete(String id) async {
    final ps = await _read();
    ps.removeWhere((p) => p.id == id);
    await _write(ps);
  }
}
