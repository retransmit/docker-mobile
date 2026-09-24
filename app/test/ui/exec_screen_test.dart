import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:xterm/xterm.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/exec_screen.dart';

import '../support/fake_transport.dart';

void main() {
  testWidgets('renders the terminal and command bar, then shows session ended', (tester) async {
    final fake = FakeTransport()
      ..onGet(RegExp(r'/exec/[^/]+/json$'), (_) => http.Response('{"Running":false,"ExitCode":0}', 200))
      ..onPost(RegExp('.*'), (_) => http.Response('{"Id":"e1"}', 201)); // exec create and resize
    await tester.pumpWidget(
      ProviderScope(
        overrides: [transportProvider.overrideWith((ref) => fake)],
        child: const MaterialApp(home: ExecScreen(containerId: 'a', containerName: 'web')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget); // app bar title
    expect(find.byType(TerminalView), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget); // command bar

    await fake.lastChannel.controller.close(); // process exits
    await tester.pumpAndSettle();
    expect(find.textContaining('ended'), findsOneWidget);
  });
}
