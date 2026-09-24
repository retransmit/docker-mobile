import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:convert';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/pull_sheet.dart';

import '../support/fake_transport.dart';

FakeTransport pullFake(List<int> pullBytes) =>
    FakeTransport()..onPostStream(RegExp(r'/images/create'), (_) => Stream.value(pullBytes));

void main() {
  testWidgets('streams progress for a pulled ref', (tester) async {
    final t = pullFake(utf8.encode('{"status":"Pulling fs layer","id":"l1"}\n{"status":"Pull complete","id":"l1"}\n'));
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: PullSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nginx:1.27');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Pull'));
    await tester.pumpAndSettle();

    expect(t.calls.lastWhere((c) => c.method == 'POSTSTREAM').query, {'fromImage': 'nginx', 'tag': '1.27'});
    expect(find.textContaining('Pull complete'), findsWidgets);
  });

  testWidgets('surfaces an error event', (tester) async {
    final t = pullFake(utf8.encode('{"error":"manifest unknown"}\n'));
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: PullSheet()),
    ));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'nope');
    await tester.tap(find.widgetWithText(ElevatedButton, 'Pull'));
    await tester.pumpAndSettle();

    expect(find.textContaining('manifest unknown'), findsOneWidget);
  });
}
