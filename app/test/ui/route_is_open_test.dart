import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/ui/route_is_open.dart';

/// The context of the pushed screen, kept for the test.
late BuildContext _screen;

/// Pumps a first route and pushes a screen over it. What the screen's route
/// completes with ends up in [results].
Future<NavigatorState> _pumpScreen(WidgetTester tester, List<Object?> results) async {
  await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('first'))));
  final navigator = tester.state<NavigatorState>(find.byType(Navigator));
  navigator
      .push<Object?>(MaterialPageRoute(builder: (context) {
        _screen = context;
        return const Scaffold(body: Text('screen'));
      }))
      .then(results.add);
  await tester.pumpAndSettle();
  return navigator;
}

void main() {
  testWidgets('routeIsOpen turns false in the call that pops the route, while its widgets are still mounted', (tester) async {
    final navigator = await _pumpScreen(tester, []);
    expect(routeIsOpen(_screen), isTrue);

    navigator.pop();
    expect(_screen.mounted, isTrue);
    expect(routeIsOpen(_screen), isFalse);
    await tester.pumpAndSettle();
  });

  testWidgets('closeRoute closes its route and hands the result to whoever pushed it', (tester) async {
    final results = <Object?>[];
    await _pumpScreen(tester, results);

    closeRoute(_screen, 'done');
    await tester.pumpAndSettle();
    expect(find.text('screen'), findsNothing);
    expect(find.text('first'), findsOneWidget);
    expect(results, ['done']);
  });

  testWidgets('closeRoute also closes what was pushed on top of its route', (tester) async {
    final results = <Object?>[];
    final navigator = await _pumpScreen(tester, results);
    navigator.push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('on top'))));
    navigator.push<void>(DialogRoute(context: navigator.context, builder: (_) => const AlertDialog(title: Text('and a dialog'))));
    await tester.pumpAndSettle();
    expect(find.text('and a dialog'), findsOneWidget);

    closeRoute(_screen, 7);
    await tester.pumpAndSettle();
    expect(find.text('and a dialog'), findsNothing);
    expect(find.text('on top'), findsNothing);
    expect(find.text('screen'), findsNothing);
    expect(find.text('first'), findsOneWidget);
    expect(results, [7]);
  });

  testWidgets('closeRoute leaves the routes alone when its own was closed already', (tester) async {
    final results = <Object?>[];
    final navigator = await _pumpScreen(tester, results);

    navigator.pop(); // closed underneath; the screen is still mounted until its transition ends
    closeRoute(_screen, 'late');
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(results, [null]);
  });

  testWidgets('closeRoute does nothing for a screen that is gone', (tester) async {
    final results = <Object?>[];
    final navigator = await _pumpScreen(tester, results);
    navigator.pop();
    await tester.pumpAndSettle();
    expect(_screen.mounted, isFalse);

    closeRoute(_screen, 'late');
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(results, [null]);
  });
}
