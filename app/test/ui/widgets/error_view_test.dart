import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/ui/widgets/error_view.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('shows the kind title, the message, the icon and Retry', (tester) async {
    var retried = 0;
    await tester.pumpWidget(_wrap(ErrorView(
      error: DockerError.fromResponse(404, '{"message":"No such container: web"}'),
      onRetry: () => retried++,
    )));
    expect(find.text('Not found'), findsOneWidget);
    expect(find.text('No such container: web'), findsOneWidget);
    expect(find.byIcon(Icons.search_off), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retried, 1);
  });

  testWidgets('network and timeout kinds get their icons', (tester) async {
    await tester.pumpWidget(_wrap(const ErrorView(error: DockerError(DockerErrorKind.network, 'down'))));
    expect(find.byIcon(Icons.wifi_off), findsOneWidget);
    expect(find.text('Cannot reach the daemon'), findsOneWidget);
    await tester.pumpWidget(_wrap(const ErrorView(error: DockerError(DockerErrorKind.timeout, 'slow'))));
    expect(find.byIcon(Icons.timer_off), findsOneWidget);
    expect(find.text('Timed out'), findsOneWidget);
  });

  testWidgets('wraps a non-DockerError and hides Retry without a callback', (tester) async {
    await tester.pumpWidget(_wrap(ErrorView(error: StateError('Not connected'))));
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.text('Bad state: Not connected'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('secondary action renders below Retry', (tester) async {
    await tester.pumpWidget(_wrap(ErrorView(
      error: const DockerError(DockerErrorKind.server, 'boom'),
      onRetry: () {},
      secondary: TextButton(onPressed: () {}, child: const Text('Disconnect')),
    )));
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Disconnect'), findsOneWidget);
  });

  testWidgets('scrollable variant lives in a ListView so pull-to-refresh works', (tester) async {
    await tester.pumpWidget(_wrap(const ErrorView(error: DockerError(DockerErrorKind.server, 'boom'), scrollable: true)));
    expect(find.byType(ListView), findsOneWidget);
    expect(find.text('boom'), findsOneWidget);
  });
}
