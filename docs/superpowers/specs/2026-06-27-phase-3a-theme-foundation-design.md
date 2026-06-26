# docker-mobile Phase 3A — Theme Foundation (M3 Expressive + Dynamic Color + Dark) — Design Spec

**Date:** 2026-06-27
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** All prior phases (on `main`). First slice of the visual-polish work; per-screen redesigns follow as their own slices.

---

## 1. Summary

Phase 3A replaces the app's default `colorSchemeSeed: Colors.blue` theme with a centralized **Material 3 Expressive** `ThemeData` (light **and dark**), **dynamic color** (Material You — derived from the wallpaper on Android 12+, with a seed fallback), and a **Settings screen** to control theme mode / dynamic color / fallback accent. Because it restyles every shared component, the whole app's look lifts at once and gains dark mode.

## 2. Goals / Non-goals

**Goals**
- `buildAppTheme(ColorScheme) → ThemeData` — one Expressive theme builder for light & dark (typography, shape, component themes).
- `StatusColors` `ThemeExtension` — brightness-aware running/paused/stopped/danger colors (replacing today's hardcoded `Colors.green`/`grey`).
- **Dynamic color** via `dynamic_color`'s `DynamicColorBuilder`, falling back to `ColorScheme.fromSeed(seed, brightness)`.
- `ThemeSettings` (mode/useDynamicColor/seed) persisted in a `SettingsStore` (reuses `flutter_secure_storage`); a `themeSettingsProvider`.
- `SettingsScreen` (theme mode / dynamic toggle / accent swatches) reached via a gear on the Connections app bar; `main.dart` rewired.

**Non-goals (this slice → later slices)**
- Per-screen layout redesigns (Connections/Containers rows, detail hero, dashboard cards, empty states, monospace IDs) — follow-on slices on top of this theme.
- Custom motion/animation, custom fonts/Google Fonts, an onboarding/splash redesign.
- Theming the `xterm` terminal or `fl_chart` internals beyond passing theme colors.

## 3. Scope decisions (locked)

- **Material 3 Expressive aesthetic** via `ThemeData` (type scale, varied shape, tonal surfaces, component themes) — targets the Expressive *look* with stable APIs; uses genuinely-Expressive widgets only where Flutter 3.44 ships them stable, else approximates (no dependence on unreleased Expressive-only widgets).
- **Dynamic color default ON** (Android 12+); fallback seed default **Docker blue `0xFF2496ED`**; schemes `.harmonized()`.
- **Theme mode default = System**; manual System/Light/Dark via Settings; persisted.
- **Settings entry:** a gear `IconButton` on `ProfilesScreen` (Connections) app bar → pushed `SettingsScreen`.
- **Persistence:** a `SettingsStore` over `flutter_secure_storage` (no new prefs dep); only `dynamic_color` is added.
- **Provider self-initializes** to defaults and async-loads persisted settings (one-frame default on cold start is acceptable; keeps `main`/tests simple — no required override).
- **Status colors** become theme-aware via the extension; the few hardcoded color usages (container rows, state badges) switch to it.

## 4. Architecture

```
main(): WidgetsFlutterBinding.ensureInitialized(); runApp(ProviderScope(child: DockerMobileApp()))

DockerMobileApp (ConsumerWidget)
  DynamicColorBuilder(builder: (lightDynamic, darkDynamic) {
    final s = ref.watch(themeSettingsProvider);
    light = (s.useDynamicColor && lightDynamic != null) ? lightDynamic.harmonized()
                                                        : ColorScheme.fromSeed(Color(s.seed));
    dark  = (s.useDynamicColor && darkDynamic  != null) ? darkDynamic.harmonized()
                                                        : ColorScheme.fromSeed(Color(s.seed), Brightness.dark);
    return MaterialApp(theme: buildAppTheme(light), darkTheme: buildAppTheme(dark),
                       themeMode: s.mode, home: ProfilesScreen());
  })

buildAppTheme(ColorScheme) -> ThemeData          [lib/src/theme/app_theme.dart]
  + StatusColors ThemeExtension                   (running/paused/stopped/danger per brightness)

ThemeSettings {mode, useDynamicColor, seed}       [lib/src/theme/theme_settings.dart]
SettingsStore (flutter_secure_storage)            [lib/src/storage/settings_store.dart]
themeSettingsProvider (StateNotifier, persists)   [lib/src/state/providers.dart or theme/]

SettingsScreen  <- gear on ProfilesScreen app bar  [lib/src/ui/settings_screen.dart]
```

## 5. Components

### 5.1 Theme — `lib/src/theme/app_theme.dart`
- `class StatusColors extends ThemeExtension<StatusColors> { final Color running, paused, stopped, danger; const StatusColors({...}); copyWith(...); lerp(...); static StatusColors of(BuildContext); }` + `statusColorsFor(Brightness) → StatusColors` (green/amber/grey/red tuned per brightness).
- `ThemeData buildAppTheme(ColorScheme scheme)`:
  - `ThemeData(colorScheme: scheme, useMaterial3: true)` then `.copyWith(...)` with: Expressive `textTheme` (bolder display/headline weights, clear hierarchy); `cardTheme` (filled `surfaceContainer`, radius ~18, low/zero elevation); `appBarTheme` (surface-tint, no shadow); `chipTheme` + `segmentedButtonTheme` + `filledButtonTheme`/`elevatedButtonTheme` (rounded, comfortable padding); `navigationBarTheme` (indicator, label behavior); `inputDecorationTheme` (filled, rounded); `dialogTheme`; `snackBarTheme`; `listTileTheme` (shape/padding); `extensions: [statusColorsFor(scheme.brightness)]`.

### 5.2 Settings model + store
- `lib/src/theme/theme_settings.dart`: `class ThemeSettings { final ThemeMode mode; final bool useDynamicColor; final int seed; const ThemeSettings({this.mode = ThemeMode.system, this.useDynamicColor = true, this.seed = 0xFF2496ED}); copyWith(...); toJson()/fromJson(); }`.
- `lib/src/storage/settings_store.dart`: `class SettingsStore { Future<void> save(ThemeSettings); Future<ThemeSettings> load(); }` over `flutter_secure_storage` key `theme_settings` (returns defaults when absent); plus an injectable in-memory variant for tests (or constructor takes a `FlutterSecureStorage`).

### 5.3 State
- `settingsStoreProvider = Provider<SettingsStore>(...)`.
- `themeSettingsProvider = StateNotifierProvider<ThemeSettingsNotifier, ThemeSettings>((ref) => ThemeSettingsNotifier(ref.watch(settingsStoreProvider))..load());` where the notifier starts at `const ThemeSettings()`, `load()` reads the store → state, and `setMode/setDynamic/setSeed` update state + persist.

### 5.4 UI — `SettingsScreen` + entry
- `lib/src/ui/settings_screen.dart` (`ConsumerWidget`): app bar "Settings"; a **Theme** `SegmentedButton<ThemeMode>` (System/Light/Dark → `setMode`); a **Dynamic colors** `SwitchListTile` (→ `setDynamic`); a row of **accent** color swatches (a small fixed palette incl. Docker blue → `setSeed`), shown as the fallback (subtle hint when dynamic is on).
- `ProfilesScreen`: add a gear `IconButton(Icons.settings)` to the app-bar `actions` → `Navigator.push(SettingsScreen())`.

### 5.5 Status-color adoption
- Replace hardcoded `Colors.green`/`Colors.grey` in `containers_screen.dart` (row icon) and `container_detail_screen.dart` (state badge) with `StatusColors.of(context)` lookups (running→running, stopped→stopped, etc.). (Minimal, the only hardcoded-color spots.)

### 5.6 `main.dart`
- Rewrite to the §4 `DynamicColorBuilder` + themed `MaterialApp` (as `DockerMobileApp` becomes a `ConsumerWidget`).

## 6. Data flow & error handling
- Cold start: provider defaults → `load()` resolves persisted settings → theme rebuilds. Changing a setting in Settings → notifier updates state (live theme change) + persists best-effort.
- `DynamicColorBuilder` returns null dynamic schemes on iOS / pre-12 Android → seed fallback. A store read failure → defaults.
- No secrets; theme prefs are non-sensitive (stored in secure storage only to avoid a new dep).

## 7. File structure
```
app/lib/src/theme/app_theme.dart                  # buildAppTheme + StatusColors
app/lib/src/theme/theme_settings.dart             # ThemeSettings model
app/lib/src/storage/settings_store.dart           # SettingsStore (secure storage)
app/lib/src/state/providers.dart                  # + settingsStoreProvider + themeSettingsProvider (+ notifier, or its own file)
app/lib/src/ui/settings_screen.dart               # SettingsScreen
app/lib/src/ui/profiles_screen.dart               # + gear -> Settings
app/lib/src/ui/containers_screen.dart             # status colors via extension
app/lib/src/ui/container_detail_screen.dart       # status badge via extension
app/lib/main.dart                                  # DynamicColorBuilder + themed MaterialApp
app/pubspec.yaml                                   # + dynamic_color
app/test/...                                        # mirrors the above
```

## 8. Testing
- `buildAppTheme`: light scheme → `ThemeData` with `useMaterial3 == true`, `colorScheme.brightness == light`, and a non-null `StatusColors` extension; dark scheme → `brightness == dark`; `statusColorsFor(dark) != statusColorsFor(light)`.
- `ThemeSettings`/`SettingsStore`: round-trip mode/useDynamicColor/seed via the in-memory store; absent → defaults.
- `themeSettingsProvider`: `setMode(dark)` updates state and persists (assert via the injected store); `setSeed`/`setDynamic` likewise.
- `SettingsScreen`: renders the Theme segmented control + Dynamic switch + swatches; tapping **Dark** sets `mode == ThemeMode.dark`; tapping a swatch updates `seed`. The **gear** on `ProfilesScreen` opens `SettingsScreen`.
- Boot: the app builds with both themes and lands on `ProfilesScreen` (existing `widget_test` stays green; add a dark-mode boot assertion if practical).
- Existing widget tests remain green (they pump bare `MaterialApp`s; the theme change doesn't alter finders).

## 9. Dependencies
- **Add:** `dynamic_color`. (Reuses `flutter_secure_storage` for persistence.)

## 10. Open questions / to confirm during planning
- `dynamic_color` version: pin current stable; `DynamicColorBuilder` + `ColorScheme.harmonized()` API is stable across recent majors — adapt if member names differ.
- Whether Flutter 3.44 exposes stable M3 Expressive widgets (e.g. button groups, new FAB sizes); if not, approximate the look via shapes/typography and note it.
- Accent swatch set: a small curated palette (Docker blue, teal, indigo, green, orange) — confirm the list during planning; dynamic-on hides/dims them.
