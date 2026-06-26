import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/theme/theme_settings.dart';
import 'package:docker_mobile/src/storage/settings_store.dart';
import 'package:docker_mobile/src/state/theme_provider.dart';

void main() {
  test('notifier loads from the store and persists changes', () async {
    final store = InMemorySettingsStore()..save(const ThemeSettings(mode: ThemeMode.dark));
    final container = ProviderContainer(overrides: [settingsStoreProvider.overrideWithValue(store)]);
    addTearDown(container.dispose);

    container.read(themeSettingsProvider); // instantiate notifier -> triggers _load()
    await Future<void>.delayed(Duration.zero); // let _load() resolve
    expect(container.read(themeSettingsProvider).mode, ThemeMode.dark);

    container.read(themeSettingsProvider.notifier).setSeed(0xFF6366F1);
    expect(container.read(themeSettingsProvider).seed, 0xFF6366F1);
    expect((await store.load()).seed, 0xFF6366F1); // persisted
  });
}
