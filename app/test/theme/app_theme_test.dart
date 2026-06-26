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
