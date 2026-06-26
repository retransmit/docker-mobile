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
