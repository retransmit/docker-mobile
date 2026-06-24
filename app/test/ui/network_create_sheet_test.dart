import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/network_create_sheet.dart';

class _FakeTransport implements Transport {
  Map<String, dynamic>? createBody;
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => http.Response('[]', 200);
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    if (path == '/networks/create') createBody = body as Map<String, dynamic>;
    return http.Response('{"Id":"n9"}', 201);
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

void main() {
  testWidgets('fills the form and creates a network with subnet + label', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: NetworkCreateSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'mynet');

    // Add one IPAM subnet row.
    await tester.tap(find.widgetWithText(OutlinedButton, 'Add subnet'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Subnet (CIDR)'), '10.0.0.0/24');

    // Add one label via the Labels KeyValueEditor (first Add icon belongs to Labels).
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'key'), 'env');
    await tester.enterText(find.widgetWithText(TextField, 'value'), 'prod');
    await tester.pump();

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(t.createBody, isNotNull);
    expect(t.createBody!['Name'], 'mynet');
    expect(t.createBody!['IPAM']['Config'], [
      {'Subnet': '10.0.0.0/24'}
    ]);
    expect(t.createBody!['Labels'], {'env': 'prod'});
  });

  testWidgets('Create is disabled until a name is entered', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: NetworkCreateSheet()),
    ));
    await tester.pumpAndSettle();

    final btn = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Create'));
    expect(btn.onPressed, isNull); // disabled
  });
}
