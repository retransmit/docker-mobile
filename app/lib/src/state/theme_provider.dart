import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../storage/settings_store.dart';
import '../theme/theme_settings.dart';

final settingsStoreProvider = Provider<SettingsStore>((ref) => SecureSettingsStore());

class ThemeSettingsNotifier extends StateNotifier<ThemeSettings> {
  final SettingsStore _store;
  ThemeSettingsNotifier(this._store) : super(const ThemeSettings()) {
    _load();
  }

  Future<void> _load() async => state = await _store.load();

  // Persist best-effort: the live theme already changed, so a write failure
  // must not surface as an unhandled async error (matches the app's pattern).
  void _persist() => _store.save(state).catchError((Object _) {});

  void setMode(ThemeMode mode) {
    state = state.copyWith(mode: mode);
    _persist();
  }

  void setDynamic(bool useDynamicColor) {
    state = state.copyWith(useDynamicColor: useDynamicColor);
    _persist();
  }

  void setSeed(int seed) {
    state = state.copyWith(seed: seed);
    _persist();
  }
}

final themeSettingsProvider = StateNotifierProvider<ThemeSettingsNotifier, ThemeSettings>(
  (ref) => ThemeSettingsNotifier(ref.watch(settingsStoreProvider)),
);
