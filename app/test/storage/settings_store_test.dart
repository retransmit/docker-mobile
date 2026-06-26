import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/theme/theme_settings.dart';
import 'package:docker_mobile/src/storage/settings_store.dart';

void main() {
  test('ThemeSettings json round-trips', () {
    const s = ThemeSettings(mode: ThemeMode.dark, useDynamicColor: false, seed: 0xFF14B8A6);
    final s2 = ThemeSettings.fromJson(s.toJson());
    expect(s2.mode, ThemeMode.dark);
    expect(s2.useDynamicColor, isFalse);
    expect(s2.seed, 0xFF14B8A6);
  });

  test('defaults: system mode, dynamic on, docker-blue seed', () {
    const s = ThemeSettings();
    expect(s.mode, ThemeMode.system);
    expect(s.useDynamicColor, isTrue);
    expect(s.seed, 0xFF2496ED);
  });

  test('InMemorySettingsStore save/load; absent -> defaults', () async {
    final store = InMemorySettingsStore();
    expect((await store.load()).mode, ThemeMode.system); // default
    await store.save(const ThemeSettings(mode: ThemeMode.light, seed: 0xFF22C55E));
    final loaded = await store.load();
    expect(loaded.mode, ThemeMode.light);
    expect(loaded.seed, 0xFF22C55E);
  });
}
