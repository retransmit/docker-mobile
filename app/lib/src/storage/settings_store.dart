import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../theme/theme_settings.dart';

abstract class SettingsStore {
  Future<void> save(ThemeSettings settings);
  Future<ThemeSettings> load();
}

class InMemorySettingsStore implements SettingsStore {
  ThemeSettings _s = const ThemeSettings();
  @override
  Future<void> save(ThemeSettings settings) async => _s = settings;
  @override
  Future<ThemeSettings> load() async => _s;
}

class SecureSettingsStore implements SettingsStore {
  static const _key = 'theme_settings';
  final FlutterSecureStorage _storage;
  SecureSettingsStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  @override
  Future<void> save(ThemeSettings settings) => _storage.write(key: _key, value: jsonEncode(settings.toJson()));

  @override
  Future<ThemeSettings> load() async {
    final v = await _storage.read(key: _key);
    if (v == null) return const ThemeSettings();
    try {
      return ThemeSettings.fromJson(jsonDecode(v) as Map<String, dynamic>);
    } catch (_) {
      return const ThemeSettings();
    }
  }
}
