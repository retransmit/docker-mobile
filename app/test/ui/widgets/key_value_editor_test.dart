import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/ui/widgets/key_value_editor.dart';

void main() {
  testWidgets('adds a row, emits the typed key/value, and removes it', (tester) async {
    Map<String, String> emitted = {};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: KeyValueEditor(title: 'Labels', onChanged: (m) => emitted = m),
      ),
    ));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'key'), 'env');
    await tester.enterText(find.widgetWithText(TextField, 'value'), 'prod');
    await tester.pump();
    expect(emitted, {'env': 'prod'});

    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pumpAndSettle();
    expect(emitted, isEmpty);
  });
}
