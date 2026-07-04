import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/ui/widgets/skeletons.dart';

Widget _host(Widget c) => MaterialApp(home: Scaffold(body: c));

void main() {
  testWidgets('SkeletonList renders a Shimmer over N card rows', (tester) async {
    await tester.pumpWidget(_host(const SkeletonList(rows: 4)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(Shimmer), findsOneWidget);
    expect(find.byType(Card), findsNWidgets(4));
  });

  testWidgets('SkeletonCards renders a Shimmer over N cards', (tester) async {
    await tester.pumpWidget(_host(const SkeletonCards(count: 2)));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byType(Shimmer), findsOneWidget);
    expect(find.byType(Card), findsNWidgets(2));
  });

  testWidgets('SkeletonBox renders', (tester) async {
    await tester.pumpWidget(_host(const SkeletonBox(height: 12)));
    await tester.pump();
    expect(find.byType(SkeletonBox), findsOneWidget);
  });
}
