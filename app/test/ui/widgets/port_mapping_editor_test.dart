import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/container_create_config.dart';
import 'package:docker_mobile/src/ui/widgets/port_mapping_editor.dart';

void main() {
  testWidgets('add a row, type host/container, emits a PortMapping; remove clears it', (tester) async {
    List<PortMapping> emitted = [];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: PortMappingEditor(onChanged: (v) => emitted = v)),
    ));
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'host').first, '8080');
    await tester.enterText(find.widgetWithText(TextField, 'container').first, '80');
    await tester.pump();

    expect(emitted.length, 1);
    expect(emitted.single.hostPort, '8080');
    expect(emitted.single.containerPort, '80');
    expect(emitted.single.protocol, 'tcp');

    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pump();
    expect(emitted, isEmpty);
  });
}
