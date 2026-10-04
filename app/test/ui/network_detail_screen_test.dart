import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/network_detail_screen.dart';

import '../support/fake_transport.dart';
import '../support/held_transport.dart';

FakeTransport networkFake([FakeTransport? base]) => (base ?? FakeTransport())
  ..onGet('/networks/n1', (_) => http.Response(
        '{"Id":"n1","Name":"mynet","Driver":"bridge","Scope":"local","Internal":true,"IPAM":{"Driver":"default","Config":[{"Subnet":"10.0.0.0/24","Gateway":"10.0.0.1"}]},"Containers":{"abc":{"Name":"web","IPv4Address":"10.0.0.2/24"}},"Labels":{"env":"prod"}}',
        200,
      ))
  ..onDelete('/networks/n1', (_) => http.Response('', 204));

Future<void> _open(WidgetTester tester, Transport t) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [transportProvider.overrideWith((ref) => t)],
    child: MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(child: ElevatedButton(
            onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => const NetworkDetailScreen(networkId: 'n1', title: 'mynet'))),
            child: const Text('open'),
          )),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// Opens the screen and confirms Remove; the delete stays in flight until `release()`.
Future<HeldTransport> _startRemove(WidgetTester tester) async {
  final t = HeldTransport();
  await _open(tester, networkFake(t));
  await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(TextButton, 'Remove')); // confirm
  await tester.pumpAndSettle();
  return t;
}

void main() {
  testWidgets('renders detail + connected containers and removes', (tester) async {
    final t = networkFake();
    await _open(tester, t);

    expect(find.text('mynet'), findsOneWidget); // app bar title
    expect(find.textContaining('10.0.0.0/24'), findsWidgets); // subnet
    expect(find.textContaining('web'), findsWidgets); // connected container

    await tester.tap(find.widgetWithText(ElevatedButton, 'Remove'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Remove')); // confirm
    await tester.pumpAndSettle();

    expect(t.calls.where((c) => c.method == 'DELETE').map((c) => c.path), contains('/networks/n1'));
    expect(find.text('open'), findsOneWidget); // popped back
  });

  testWidgets('a screen closed underneath a pending remove does not close the screen below', (tester) async {
    final t = await _startRemove(tester);
    popToFirstRoute(tester); // the screen is on its way out, and still mounted until its transition ends
    t.release();
    await tester.pumpAndSettle();

    expect(t.calls.where((c) => c.method == 'DELETE'), hasLength(1)); // the remove did answer
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a finished remove closes its own screen and what is on top of it', (tester) async {
    final t = await _startRemove(tester);
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push<void>(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('on top'))));
    await tester.pumpAndSettle();
    expect(find.text('on top'), findsOneWidget);

    t.release();
    await tester.pumpAndSettle();
    expect(find.text('on top', skipOffstage: false), findsNothing);
    expect(find.byType(NetworkDetailScreen, skipOffstage: false), findsNothing);
    expect(find.text('open'), findsOneWidget); // the screen below is on top again
    expect(find.text('Removed'), findsOneWidget);
  });

  testWidgets('a remove that answers after the screen is gone reports no failure', (tester) async {
    final t = await _startRemove(tester);
    popToFirstRoute(tester);
    await tester.pumpAndSettle(); // the screen is disposed by now
    t.release();
    await tester.pumpAndSettle();

    expect(t.calls.where((c) => c.method == 'DELETE'), hasLength(1));
    expect(find.textContaining('Failed'), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });
}
