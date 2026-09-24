import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/container_detail_screen.dart';
import 'package:docker_mobile/src/ui/widgets/error_view.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';

import '../support/fake_transport.dart';

FakeTransport containerFake({
  String status = 'running', // container State.Status
  bool running = true,
  bool paused = false,
  int actionStatus = 204, // status returned by post/delete
}) =>
    FakeTransport()
      ..onGet('/containers/a/json', (_) => http.Response(
            '{"Id":"a","Name":"/web","Config":{"Image":"nginx"},"State":{"Status":"$status","Running":$running,"Paused":$paused}}',
            200,
          ))
      ..onPost(RegExp('.*'), (_) => http.Response('', actionStatus))
      ..onDelete(RegExp('.*'), (_) => http.Response('', actionStatus));

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ContainerDetailScreen(containerId: 'a', containerName: 'web')),
    );

void main() {
  testWidgets('renders detail and a stopped container offers Start', (tester) async {
    final t = containerFake(status: 'exited', running: false);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    expect(find.text('web'), findsOneWidget); // app bar title
    // hero shows the status via a StatusPill and the image via MonoText
    expect(find.byType(StatusPill), findsOneWidget);
    expect(find.textContaining('nginx'), findsWidgets); // image shown (hero, once)
    // primary actions present and grouped at the top
    expect(find.widgetWithText(FilledButton, 'Logs'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Exec'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Stats'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Start'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pumpAndSettle();
    expect(t.posts.map((c) => c.path), contains('/containers/a/start'));
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('a running container shows Stop/Restart/Pause and hides Start', (tester) async {
    final t = containerFake(status: 'running', running: true);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Start'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Stop'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Restart'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Pause'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Unpause'), findsNothing);
    // actions live under a titled card
    expect(find.widgetWithText(Card, 'Actions'), findsOneWidget);
    // Remove is now a FilledButton (error styled)
    expect(find.widgetWithText(FilledButton, 'Remove'), findsOneWidget);
  });

  testWidgets('a paused container offers Unpause and hides Stop/Pause', (tester) async {
    final t = containerFake(status: 'paused', running: true, paused: true);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(FilledButton, 'Unpause'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Pause'), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Stop'), findsNothing);
  });

  testWidgets('Remove opens a confirmation dialog and confirming calls delete', (tester) async {
    final t = containerFake(status: 'exited', running: false);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Force'), findsOneWidget);

    // Confirm (the dialog's TextButton labelled 'Remove').
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(t.calls.where((c) => c.method == 'DELETE').map((c) => c.path), contains('/containers/a'));
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('a failing action shows an error snackbar', (tester) async {
    final t = containerFake(status: 'exited', running: false, actionStatus: 500);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Start'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed'), findsOneWidget);
  });

  testWidgets('Rename dialog renames the container without a controller crash', (tester) async {
    final t = containerFake(status: 'running', running: true);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'newname');
    await tester.tap(find.widgetWithText(TextButton, 'Rename')); // dialog confirm
    await tester.pumpAndSettle();

    expect(t.posts.map((c) => c.path), contains('/containers/a/rename'));
  });

  testWidgets('renders an ErrorView with Retry when loading fails', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          containerDetailProvider.overrideWith(
            (ref, id) async => throw DockerError.fromResponse(500, '{"message":"boom"}'),
          ),
        ],
        child: const MaterialApp(home: ContainerDetailScreen(containerId: 'a', containerName: 'web')),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(ErrorView), findsOneWidget);
    expect(find.text('Daemon error'), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byType(StatusPill), findsNothing);
  });
}
