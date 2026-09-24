import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/connect/disconnect.dart';

import '../support/fake_transport.dart';

void main() {
  testWidgets('disconnect pops to the first route, nulls and closes the transport', (tester) async {
    final fake = FakeTransport();
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => fake)],
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          container = ProviderScope.containerOf(ctx);
          return Scaffold(
            body: Center(child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(MaterialPageRoute(
                builder: (_) => Consumer(builder: (c, ref, _) => Scaffold(
                  body: Center(child: ElevatedButton(
                    onPressed: () => disconnect(c, ref),
                    child: const Text('disconnect'),
                  )),
                )),
              )),
              child: const Text('go'),
            )),
          );
        }),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('disconnect'));
    await tester.pumpAndSettle();

    expect(container.read(transportProvider), isNull);
    expect(fake.closed, isTrue);
    expect(find.text('go'), findsOneWidget); // back on the first route
    expect(find.text('disconnect'), findsNothing);
  });
}
