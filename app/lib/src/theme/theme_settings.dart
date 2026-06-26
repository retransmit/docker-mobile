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
