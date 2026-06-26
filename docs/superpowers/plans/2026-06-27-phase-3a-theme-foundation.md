# Phase 3A — Theme Foundation (M3 Expressive + Dynamic Color + Dark) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A centralized Material 3 Expressive theme (light + dark) with dynamic color and a Settings screen, lifting the whole app's look at once.

**Architecture:** `buildAppTheme(ColorScheme)` produces an Expressive `ThemeData` for light & dark; `main` wraps `MaterialApp` in `DynamicColorBuilder` (wallpaper colors, seed fallback) and drives `themeMode` from a persisted `themeSettingsProvider`; a `SettingsScreen` (reached via a gear on Connections) controls it. A `StatusColors` theme extension replaces hardcoded status colors.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod`, `dynamic_color` (new), `flutter_secure_storage` (reused).

## Global Constraints

- **App-only slice:** no agent changes. New dep: **`dynamic_color`** only (persistence reuses `flutter_secure_storage`).
- **Material 3 Expressive aesthetic** via `ThemeData` (type/shape/tonal surfaces/component themes); approximate where Flutter 3.44 lacks stable Expressive widgets.
- **Dynamic color default ON** (Android 12+); `.harmonized()`; fallback seed default `0xFF2496ED` (Docker blue). **Theme mode default = System.**
- **Settings entry:** a gear `IconButton(Icons.settings)` on `ProfilesScreen` app bar → pushed `SettingsScreen`.
- **Provider self-initializes** to `const ThemeSettings()` and async-loads persisted settings; `set*` methods persist best-effort.
- **Status colors** become theme-aware (`StatusColors.of(context)`); replace the hardcoded `Colors.green`/`grey` in `containers_screen.dart` + `container_detail_screen.dart`.
- **Flutter-3.44 theme-data classes:** use `CardThemeData`/`DialogThemeData`/`WidgetStatePropertyAll` (the current names); if the installed SDK differs, adapt the member name and keep the styling.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/theme/app_theme.dart                  # buildAppTheme + StatusColors + statusColorsFor
app/lib/src/theme/theme_settings.dart             # ThemeSettings model
app/lib/src/storage/settings_store.dart           # SettingsStore (interface + Secure + InMemory)
app/lib/src/state/theme_provider.dart             # settingsStoreProvider + ThemeSettingsNotifier + themeSettingsProvider
app/lib/src/ui/settings_screen.dart               # SettingsScreen
app/lib/src/ui/profiles_screen.dart               # + gear -> Settings
app/lib/src/ui/containers_screen.dart             # status colors via extension
app/lib/src/ui/container_detail_screen.dart       # state badge via extension
app/lib/main.dart                                  # DynamicColorBuilder + themed MaterialApp
app/pubspec.yaml                                   # + dynamic_color
app/test/...                                        # mirrors the above
```

---

## Task 1: Expressive theme + StatusColors

**Files:**
- Modify: `app/pubspec.yaml` (add `dynamic_color`)
- Create: `app/lib/src/theme/app_theme.dart`
- Test: `app/test/theme/app_theme_test.dart`

**Interfaces:**
- Produces: `ThemeData buildAppTheme(ColorScheme scheme)`; `class StatusColors extends ThemeExtension<StatusColors> { final Color running, paused, stopped, danger; static StatusColors of(BuildContext); }`; `StatusColors statusColorsFor(Brightness)`.

- [ ] **Step 1: Add the dependency**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter pub add dynamic_color`
Expected: `pubspec.yaml` gains `dynamic_color:`; `pub get` succeeds.

- [ ] **Step 2: Write the failing test**

Create `app/test/theme/app_theme_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/theme/app_theme.dart';

void main() {
  test('buildAppTheme returns an M3 theme with a StatusColors extension', () {
    final light = buildAppTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF2496ED)));
    expect(light.useMaterial3, isTrue);
    expect(light.colorScheme.brightness, Brightness.light);
    expect(light.extension<StatusColors>(), isNotNull);

    final dark = buildAppTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF2496ED), brightness: Brightness.dark));
    expect(dark.colorScheme.brightness, Brightness.dark);
  });

  test('status colors differ between light and dark', () {
    expect(statusColorsFor(Brightness.light).running, isNot(statusColorsFor(Brightness.dark).running));
    expect(statusColorsFor(Brightness.light).stopped, isNot(statusColorsFor(Brightness.dark).stopped));
  });

  testWidgets('StatusColors.of reads the theme extension', (tester) async {
    late StatusColors sc;
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(ColorScheme.fromSeed(seedColor: const Color(0xFF2496ED))),
      home: Builder(builder: (ctx) { sc = StatusColors.of(ctx); return const SizedBox(); }),
    ));
    expect(sc.running, statusColorsFor(Brightness.light).running);
  });
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/theme/app_theme_test.dart`
Expected: FAIL — `buildAppTheme`/`StatusColors` undefined.

- [ ] **Step 4: Write the theme**

Create `app/lib/src/theme/app_theme.dart`:
```dart
import 'package:flutter/material.dart';

/// Brightness-aware status colors for container state (running/paused/stopped)
/// and destructive accents. Exposed as a ThemeExtension so widgets read it via
/// `StatusColors.of(context)` instead of hardcoding Colors.green/grey.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  final Color running;
  final Color paused;
  final Color stopped;
  final Color danger;
  const StatusColors({required this.running, required this.paused, required this.stopped, required this.danger});

  @override
  StatusColors copyWith({Color? running, Color? paused, Color? stopped, Color? danger}) => StatusColors(
        running: running ?? this.running,
        paused: paused ?? this.paused,
        stopped: stopped ?? this.stopped,
        danger: danger ?? this.danger,
      );

  @override
  StatusColors lerp(ThemeExtension<StatusColors>? other, double t) {
    if (other is! StatusColors) return this;
    return StatusColors(
      running: Color.lerp(running, other.running, t)!,
      paused: Color.lerp(paused, other.paused, t)!,
      stopped: Color.lerp(stopped, other.stopped, t)!,
      danger: Color.lerp(danger, other.danger, t)!,
    );
  }

  static StatusColors of(BuildContext context) =>
      Theme.of(context).extension<StatusColors>() ?? statusColorsFor(Theme.of(context).brightness);
}

StatusColors statusColorsFor(Brightness b) => b == Brightness.dark
    ? const StatusColors(running: Color(0xFF4ADE80), paused: Color(0xFFFBBF24), stopped: Color(0xFF9CA3AF), danger: Color(0xFFF87171))
    : const StatusColors(running: Color(0xFF16A34A), paused: Color(0xFFD97706), stopped: Color(0xFF6B7280), danger: Color(0xFFDC2626));

/// The app's Material 3 Expressive theme, built from a (dynamic or seeded)
/// ColorScheme. Called for both light and dark.
ThemeData buildAppTheme(ColorScheme scheme) {
  final base = ThemeData(colorScheme: scheme, useMaterial3: true);
  return base.copyWith(
    scaffoldBackgroundColor: scheme.surface,
    textTheme: base.textTheme.copyWith(
      headlineSmall: base.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
      titleLarge: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
      titleMedium: base.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.surface,
      surfaceTintColor: scheme.surfaceTint,
      scrolledUnderElevation: 2,
      centerTitle: false,
      titleTextStyle: base.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700, color: scheme.onSurface),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerHigh,
      elevation: 0,
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
    ),
    listTileTheme: ListTileThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
    chipTheme: const ChipThemeData(shape: StadiumBorder(), side: BorderSide.none),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(shape: const StadiumBorder(), padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12)),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(style: ElevatedButton.styleFrom(shape: const StadiumBorder())),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(shape: const StadiumBorder())),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: scheme.surfaceContainer,
      indicatorColor: scheme.secondaryContainer,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      elevation: 0,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      isDense: true,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: BorderSide(color: scheme.primary, width: 2)),
    ),
    dialogTheme: DialogThemeData(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
    snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
    extensions: [statusColorsFor(scheme.brightness)],
  );
}
```
**SDK-name note:** `CardThemeData`/`DialogThemeData` and `scheme.surfaceContainer*` are the Flutter 3.44 names; if the installed SDK still uses `CardTheme`/`DialogTheme` or lacks a `surfaceContainer*` role, adapt the member name (keep `surfaceContainerHighest` → `surfaceVariant` etc.) and note it in concerns. Keep behavior/styling intent.

- [ ] **Step 5: Run the test + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/theme/app_theme_test.dart && flutter analyze`
Expected: PASS (3 tests); analyzer clean.

- [ ] **Step 6: Commit**

```bash
git add app/pubspec.yaml app/pubspec.lock app/lib/src/theme/app_theme.dart app/test/theme/app_theme_test.dart
git commit -m "feat(app): M3 Expressive theme builder + StatusColors extension (+ dynamic_color dep)"
```

---

## Task 2: ThemeSettings + SettingsStore + provider

**Files:**
- Create: `app/lib/src/theme/theme_settings.dart`, `app/lib/src/storage/settings_store.dart`, `app/lib/src/state/theme_provider.dart`
- Test: `app/test/storage/settings_store_test.dart`, `app/test/state/theme_provider_test.dart`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces:
  - `class ThemeSettings { final ThemeMode mode; final bool useDynamicColor; final int seed; const ThemeSettings({...defaults...}); copyWith(...); toJson()/fromJson(); }`
  - `abstract class SettingsStore { Future<void> save(ThemeSettings); Future<ThemeSettings> load(); }` + `SecureSettingsStore`, `InMemorySettingsStore`.
  - `settingsStoreProvider`; `class ThemeSettingsNotifier extends StateNotifier<ThemeSettings> { void setMode(ThemeMode); void setDynamic(bool); void setSeed(int); }`; `themeSettingsProvider`.

- [ ] **Step 1: Write the failing test**

Create `app/test/storage/settings_store_test.dart`:
```dart
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
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/storage/settings_store_test.dart`
Expected: FAIL — types undefined.

- [ ] **Step 3: Write the model + store**

Create `app/lib/src/theme/theme_settings.dart`:
```dart
import 'package:flutter/material.dart';

class ThemeSettings {
  final ThemeMode mode;
  final bool useDynamicColor;
  final int seed;

  const ThemeSettings({this.mode = ThemeMode.system, this.useDynamicColor = true, this.seed = 0xFF2496ED});

  ThemeSettings copyWith({ThemeMode? mode, bool? useDynamicColor, int? seed}) =>
      ThemeSettings(mode: mode ?? this.mode, useDynamicColor: useDynamicColor ?? this.useDynamicColor, seed: seed ?? this.seed);

  Map<String, dynamic> toJson() => {'mode': mode.name, 'useDynamicColor': useDynamicColor, 'seed': seed};

  factory ThemeSettings.fromJson(Map<String, dynamic> json) => ThemeSettings(
        mode: ThemeMode.values.byName(json['mode'] as String? ?? 'system'),
        useDynamicColor: json['useDynamicColor'] as bool? ?? true,
        seed: (json['seed'] as num?)?.toInt() ?? 0xFF2496ED,
      );
}
```

Create `app/lib/src/storage/settings_store.dart`:
```dart
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
```

- [ ] **Step 4: Write the failing provider test**

Create `app/test/state/theme_provider_test.dart`:
```dart
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

    await Future<void>.delayed(Duration.zero); // let _load() resolve
    expect(container.read(themeSettingsProvider).mode, ThemeMode.dark);

    container.read(themeSettingsProvider.notifier).setSeed(0xFF6366F1);
    expect(container.read(themeSettingsProvider).seed, 0xFF6366F1);
    expect((await store.load()).seed, 0xFF6366F1); // persisted
  });
}
```

- [ ] **Step 5: Write the provider**

Create `app/lib/src/state/theme_provider.dart`:
```dart
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
```

- [ ] **Step 6: Run both tests + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/storage/settings_store_test.dart test/state/theme_provider_test.dart && flutter analyze`
Expected: PASS (4 tests); analyzer clean.

- [ ] **Step 7: Commit**

```bash
git add app/lib/src/theme/theme_settings.dart app/lib/src/storage/settings_store.dart app/lib/src/state/theme_provider.dart app/test/storage/settings_store_test.dart app/test/state/theme_provider_test.dart
git commit -m "feat(app): ThemeSettings + SettingsStore + themeSettingsProvider"
```

---

## Task 3: SettingsScreen + main rewire + status-color adoption

**Files:**
- Create: `app/lib/src/ui/settings_screen.dart`
- Modify: `app/lib/src/ui/profiles_screen.dart`, `app/lib/src/ui/containers_screen.dart`, `app/lib/src/ui/container_detail_screen.dart`, `app/lib/main.dart`
- Test: `app/test/ui/settings_screen_test.dart`, and the existing `app/test/widget_test.dart` stays green

**Interfaces:**
- Consumes: `buildAppTheme`/`StatusColors` (Task 1), `themeSettingsProvider`/`settingsStoreProvider` (Task 2), `dynamic_color`'s `DynamicColorBuilder` + `ColorScheme.harmonized()`.
- Produces: `class SettingsScreen extends ConsumerWidget`; a gear on `ProfilesScreen`; themed `MaterialApp`.

- [ ] **Step 1: Write the failing test**

Create `app/test/ui/settings_screen_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/storage/settings_store.dart';
import 'package:docker_mobile/src/state/theme_provider.dart';
import 'package:docker_mobile/src/ui/settings_screen.dart';

Widget _wrap(SettingsStore store, {Widget home = const SettingsScreen()}) => ProviderScope(
      overrides: [settingsStoreProvider.overrideWithValue(store)],
      child: MaterialApp(home: home),
    );

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
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/settings_screen_test.dart`
Expected: FAIL — `SettingsScreen` undefined.

- [ ] **Step 3: Write SettingsScreen**

Create `app/lib/src/ui/settings_screen.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/theme_provider.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static const List<int> _swatches = [0xFF2496ED, 0xFF14B8A6, 0xFF6366F1, 0xFF22C55E, 0xFFF97316, 0xFFEC4899];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(themeSettingsProvider);
    final n = ref.read(themeSettingsProvider.notifier);
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text('Theme', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          SegmentedButton<ThemeMode>(
            segments: const [
              ButtonSegment(value: ThemeMode.system, label: Text('System'), icon: Icon(Icons.brightness_auto)),
              ButtonSegment(value: ThemeMode.light, label: Text('Light'), icon: Icon(Icons.light_mode)),
              ButtonSegment(value: ThemeMode.dark, label: Text('Dark'), icon: Icon(Icons.dark_mode)),
            ],
            selected: {s.mode},
            onSelectionChanged: (v) => n.setMode(v.first),
          ),
          const SizedBox(height: 16),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Dynamic colors'),
            subtitle: const Text('Use wallpaper colors (Android 12+)'),
            value: s.useDynamicColor,
            onChanged: n.setDynamic,
          ),
          const SizedBox(height: 8),
          Opacity(
            opacity: s.useDynamicColor ? 0.5 : 1.0,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Accent (used when dynamic colors are off)'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    for (final c in _swatches)
                      GestureDetector(
                        key: ValueKey('accent-0x${c.toRadixString(16).toUpperCase().padLeft(8, '0')}'),
                        onTap: () => n.setSeed(c),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: Color(c),
                            shape: BoxShape.circle,
                            border: s.seed == c ? Border.all(width: 3, color: scheme.onSurface) : null,
                          ),
                          child: s.seed == c ? const Icon(Icons.check, color: Colors.white, size: 20) : null,
                        ),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run the SettingsScreen test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/settings_screen_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Add the gear to ProfilesScreen**

In `app/lib/src/ui/profiles_screen.dart`, add `import 'settings_screen.dart';` and add an `actions:` list to the `AppBar`:
```dart
      appBar: AppBar(
        title: const Text('Connections'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Settings',
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen())),
          ),
        ],
      ),
```

- [ ] **Step 6: Rewire main.dart with DynamicColorBuilder**

Replace `app/lib/main.dart` with:
```dart
import 'package:dynamic_color/dynamic_color.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/state/theme_provider.dart';
import 'src/theme/app_theme.dart';
import 'src/ui/profiles_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ProviderScope(child: DockerMobileApp()));
}

class DockerMobileApp extends ConsumerWidget {
  const DockerMobileApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(themeSettingsProvider);
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        final lightScheme = (settings.useDynamicColor && lightDynamic != null)
            ? lightDynamic.harmonized()
            : ColorScheme.fromSeed(seedColor: Color(settings.seed));
        final darkScheme = (settings.useDynamicColor && darkDynamic != null)
            ? darkDynamic.harmonized()
            : ColorScheme.fromSeed(seedColor: Color(settings.seed), brightness: Brightness.dark);
        return MaterialApp(
          title: 'docker-mobile',
          theme: buildAppTheme(lightScheme),
          darkTheme: buildAppTheme(darkScheme),
          themeMode: settings.mode,
          home: const ProfilesScreen(),
        );
      },
    );
  }
}
```

- [ ] **Step 7: Adopt StatusColors in the container screens**

In `app/lib/src/ui/containers_screen.dart`, add `import '../theme/app_theme.dart';`, and in the `itemBuilder` replace the leading `Icon`'s color. Change:
```dart
              leading: Icon(
                c.state == 'running' ? Icons.play_circle : Icons.stop_circle,
                color: c.state == 'running' ? Colors.green : Colors.grey,
              ),
```
to:
```dart
              leading: Icon(
                c.state == 'running' ? Icons.play_circle : Icons.stop_circle,
                color: c.state == 'running' ? StatusColors.of(context).running : StatusColors.of(context).stopped,
              ),
```
In `app/lib/src/ui/container_detail_screen.dart`, add `import '../theme/app_theme.dart';`, and change the state-badge dot color so a `running`/`paused`/other state uses `StatusColors.of(context).running` / `.paused` / `.stopped` respectively (find the green/grey dot in the State row and route it through the extension; keep the same running/paused/stopped logic).

- [ ] **Step 8: Run the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; **all** app tests pass — including the existing `widget_test.dart` (the app still boots to `ProfilesScreen`; `DynamicColorBuilder` returns null dynamic schemes under test → seed fallback → builds fine). If `widget_test.dart` asserts a specific theme color, relax it to assert `find.byType(ProfilesScreen)`.

- [ ] **Step 9: Commit**

```bash
git add app/lib/src/ui/settings_screen.dart app/lib/src/ui/profiles_screen.dart app/lib/src/ui/containers_screen.dart app/lib/src/ui/container_detail_screen.dart app/lib/main.dart app/test/ui/settings_screen_test.dart
git commit -m "feat(app): SettingsScreen + dynamic-color MaterialApp + status colors via theme"
```

---

## Self-Review

**1. Spec coverage:**
- `buildAppTheme` (Expressive light/dark) + `StatusColors` extension → Task 1. ✓
- `dynamic_color` dep + `DynamicColorBuilder` + harmonized + seed fallback → Tasks 1/3. ✓
- `ThemeSettings` + `SettingsStore` (secure + in-memory) + `themeSettingsProvider` (self-load + persist) → Task 2. ✓
- `SettingsScreen` (mode segmented + dynamic switch + accent swatches) + gear on Connections → Task 3. ✓
- `themeMode` wiring in `main` → Task 3. ✓
- Status-color adoption in containers/detail → Task 3. ✓
- Out of scope (per-screen redesigns, custom fonts/motion) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete. The two SDK-name adaptation notes (theme-data class names; a brittle widget_test color assert) are bounded, explicit instructions, not placeholders.

**3. Type consistency:** `buildAppTheme(ColorScheme)` + `StatusColors`/`statusColorsFor(Brightness)`/`StatusColors.of(BuildContext)` (Task 1) used in Task 3 (`main`, containers, detail). `ThemeSettings({mode, useDynamicColor, seed})` + `copyWith`/`toJson`/`fromJson` (Task 2) used by the store/notifier/Settings/main. `SettingsStore`/`InMemorySettingsStore`/`SecureSettingsStore` (Task 2) used by the provider + test overrides. `settingsStoreProvider`/`themeSettingsProvider`/`ThemeSettingsNotifier.{setMode,setDynamic,setSeed}` (Task 2) used by `SettingsScreen` + `main` (Task 3). `SettingsScreen` (Task 3) opened by the Profiles gear (Task 3). ✓
