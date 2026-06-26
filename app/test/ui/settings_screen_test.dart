import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/storage/settings_store.dart';
import 'package:docker_mobile/src/state/theme_provider.dart';
import 'package:docker_mobile/src/ui/settings_screen.dart';

void main() {
  testWidgets('selecting Dark sets the theme mode', (tester) async {
    final store = InMemorySettingsStore();
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    container = ProviderScope.containerOf(tester.element(find.byType(SettingsScreen)));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Dark'));
    await tester.pump();
    expect(container.read(themeSettingsProvider).mode, ThemeMode.dark);
  });

  testWidgets('tapping an accent swatch updates the seed', (tester) async {
    final store = InMemorySettingsStore();
    await tester.pumpWidget(ProviderScope(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
      child: const MaterialApp(home: SettingsScreen()),
    ));
    final container = ProviderScope.containerOf(tester.element(find.byType(SettingsScreen)));
    await tester.pumpAndSettle();
    final before = container.read(themeSettingsProvider).seed;
    // tap the last swatch (a different color than the default)
    await tester.tap(find.byKey(const ValueKey('accent-0xFFEC4899')));
    await tester.pump();
    expect(container.read(themeSettingsProvider).seed, isNot(before));
  });
}
