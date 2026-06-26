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

  void setMode(ThemeMode mode) {
    state = state.copyWith(mode: mode);
    _store.save(state);
  }

  void setDynamic(bool useDynamicColor) {
    state = state.copyWith(useDynamicColor: useDynamicColor);
    _store.save(state);
  }

  void setSeed(int seed) {
    state = state.copyWith(seed: seed);
    _store.save(state);
  }
}

final themeSettingsProvider = StateNotifierProvider<ThemeSettingsNotifier, ThemeSettings>(
  (ref) => ThemeSettingsNotifier(ref.watch(settingsStoreProvider)),
);
