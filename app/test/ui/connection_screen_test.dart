import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/ui/connection_screen.dart';

void main() {
  testWidgets('a non-numeric port shows a validation error and does not crash or navigate',
      (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ConnectionScreen())),
    );

    await tester.enterText(find.byType(TextField).at(0), 'example.com'); // host
    await tester.enterText(find.byType(TextField).at(1), '80x'); // port (invalid)
    await tester.tap(find.text('Connect'));
    await tester.pump(); // surface the SnackBar

    expect(find.textContaining('valid host and port'), findsOneWidget);
    // Still on the connection screen (no navigation happened).
    expect(find.text('Connect to agent'), findsOneWidget);
  });

  testWidgets('an empty host shows a validation error', (tester) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: ConnectionScreen())),
    );

    // Host left empty; default port 8080 is valid.
    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(find.textContaining('valid host and port'), findsOneWidget);
  });
}
