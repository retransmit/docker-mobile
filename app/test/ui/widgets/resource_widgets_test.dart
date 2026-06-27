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

  testWidgets('StatCard shows value, label, sub and icon', (tester) async {
    await tester.pumpWidget(_host(const StatCard(icon: Icons.layers, value: '12', label: 'Images', sub: 'of 20')));
    expect(find.text('12'), findsOneWidget);
    expect(find.text('Images'), findsOneWidget);
    expect(find.text('of 20'), findsOneWidget);
    expect(find.byIcon(Icons.layers), findsOneWidget);
  });

  testWidgets('EmptyState shows icon + title + message + action', (tester) async {
    await tester.pumpWidget(_host(EmptyState(
      icon: Icons.dns,
      title: 'No connections',
      message: 'Add a Docker host to get started.',
      action: FilledButton(onPressed: () {}, child: const Text('Add connection')),
    )));
    expect(find.text('No connections'), findsOneWidget);
    expect(find.text('Add a Docker host to get started.'), findsOneWidget);
    expect(find.byIcon(Icons.dns), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add connection'), findsOneWidget);
  });

  testWidgets('EmptyState omits message and action when null', (tester) async {
    await tester.pumpWidget(_host(const EmptyState(icon: Icons.hub, title: 'No networks')));
    expect(find.text('No networks'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });
}
