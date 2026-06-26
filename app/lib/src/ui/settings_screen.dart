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
