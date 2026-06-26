import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/container_detail_screen.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';

class _FakeTransport implements Transport {
  @override
  Future<void> close() async {}
  final String status; // container State.Status
  final bool running;
  final bool paused;
  final int actionStatus; // status returned by post/delete
  final List<String> posts = [];
  final List<String> deletes = [];
  _FakeTransport({
    this.status = 'running',
    this.running = true,
    this.paused = false,
    this.actionStatus = 204,
  });

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response(
        '{"Id":"a","Name":"/web","Config":{"Image":"nginx"},"State":{"Status":"$status","Running":$running,"Paused":$paused}}',
        200,
      );
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(path);
    return http.Response('', actionStatus);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async {
    deletes.add(path);
    return http.Response('', actionStatus);
  }
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) =>
      const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
}

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: ContainerDetailScreen(containerId: 'a', containerName: 'web')),
    );

void main() {
  testWidgets('renders detail and a stopped container offers Start', (tester) async {
    final t = _FakeTransport(status: 'exited', running: false);
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
    expect(find.widgetWithText(ElevatedButton, 'Start'), findsOneWidget);

    await tester.tap(find.widgetWithText(ElevatedButton, 'Start'));
    await tester.pumpAndSettle();
    expect(t.posts, contains('/containers/a/start'));
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('a running container shows Stop/Restart/Pause and hides Start', (tester) async {
    final t = _FakeTransport(status: 'running', running: true);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ElevatedButton, 'Start'), findsNothing);
    expect(find.widgetWithText(ElevatedButton, 'Stop'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Restart'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Pause'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Unpause'), findsNothing);
  });

  testWidgets('a paused container offers Unpause and hides Stop/Pause', (tester) async {
    final t = _FakeTransport(status: 'paused', running: true, paused: true);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ElevatedButton, 'Unpause'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Pause'), findsNothing);
    expect(find.widgetWithText(ElevatedButton, 'Stop'), findsNothing);
  });

  testWidgets('Remove opens a confirmation dialog and confirming calls delete', (tester) async {
    final t = _FakeTransport(status: 'exited', running: false);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Force'), findsOneWidget);

    // Confirm (the dialog's TextButton labelled 'Remove').
    await tester.tap(find.widgetWithText(TextButton, 'Remove'));
    await tester.pumpAndSettle();
    expect(t.deletes, contains('/containers/a'));
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('a failing action shows an error snackbar', (tester) async {
    final t = _FakeTransport(status: 'exited', running: false, actionStatus: 500);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'Start'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed'), findsOneWidget);
  });

  testWidgets('Rename dialog renames the container without a controller crash', (tester) async {
    final t = _FakeTransport(status: 'running', running: true);
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'newname');
    await tester.tap(find.widgetWithText(TextButton, 'Rename')); // dialog confirm
    await tester.pumpAndSettle();

    expect(t.posts, contains('/containers/a/rename'));
  });
}
