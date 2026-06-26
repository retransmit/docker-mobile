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
