import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/volume_create_sheet.dart';

class _FakeTransport implements Transport {
  Map<String, dynamic>? createBody;
  int createStatus = 201;
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('{"Volumes":[]}', 200);
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    if (path == '/volumes/create') createBody = body as Map<String, dynamic>;
    return http.Response('{"Name":"data","Driver":"local"}', createStatus);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

Widget _wrap(Transport t) => ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: VolumeCreateSheet()),
    );

void main() {
  testWidgets('fills the form and creates a volume with a label', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'data');
    await tester.tap(find.byIcon(Icons.add).first); // Labels editor
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'key'), 'env');
    await tester.enterText(find.widgetWithText(TextField, 'value'), 'prod');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(t.createBody, isNotNull);
    expect(t.createBody!['Name'], 'data');
    expect(t.createBody!['Driver'], 'local');
    expect(t.createBody!['Labels'], {'env': 'prod'});
  });

  testWidgets('Create is disabled until a name is entered', (tester) async {
    await tester.pumpWidget(_wrap(_FakeTransport()));
    await tester.pumpAndSettle();
    final btn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'));
    expect(btn.onPressed, isNull);
  });

  testWidgets('a failing create shows an error snackbar without crashing', (tester) async {
    final t = _FakeTransport()..createStatus = 500;
    await tester.pumpWidget(_wrap(t));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'data');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Failed'), findsOneWidget);
  });
}
