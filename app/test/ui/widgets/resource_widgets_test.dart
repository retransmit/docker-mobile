import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('LeadingAvatar renders its icon', (tester) async {
    await tester.pumpWidget(_host(const LeadingAvatar(icon: Icons.dns)));
    expect(find.byIcon(Icons.dns), findsOneWidget);
  });

  testWidgets('StatusPill shows its label', (tester) async {
    await tester.pumpWidget(_host(const StatusPill(label: 'running', color: Colors.green)));
    expect(find.text('running'), findsOneWidget);
  });

  testWidgets('MonoText renders text in a monospace font', (tester) async {
    await tester.pumpWidget(_host(const MonoText('nginx:latest')));
    final t = tester.widget<Text>(find.text('nginx:latest'));
    expect(t.style?.fontFamily, 'monospace');
  });

  testWidgets('MetaChip shows its label', (tester) async {
    await tester.pumpWidget(_host(const MetaChip('bridge')));
    expect(find.text('bridge'), findsOneWidget);
  });
}
