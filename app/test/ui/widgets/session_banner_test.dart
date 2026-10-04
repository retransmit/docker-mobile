import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/widgets/session_banner.dart';

import '../../support/stub_session.dart';

Future<StubSession> pumpBanner(WidgetTester tester, SessionState s) async {
  final stub = StubSession(s);
  await tester.pumpWidget(ProviderScope(
    overrides: [sessionProvider.overrideWith((ref) => stub)],
    child: const MaterialApp(home: Scaffold(body: SessionBanner())),
  ));
  return stub;
}

/// Runs a route transition to its end. The reconnecting strip's spinner never
/// settles, so `pumpAndSettle` cannot be used while it shows.
Future<void> pumpTransition(WidgetTester tester) async {
  await tester.pump(); // the transition starts
  await tester.pump(const Duration(milliseconds: 600)); // and ends (the default one takes 450 ms)
  await tester.pump(); // the navigator hides or drops the route underneath
}

void main() {
  testWidgets('hidden while connected', (tester) async {
    await pumpBanner(tester, const SessionState(status: SessionStatus.connected));
    expect(find.textContaining('Reconnecting'), findsNothing);
    expect(find.text('Retry'), findsNothing);
  });

  testWidgets('reconnecting shows the attempt and a spinner', (tester) async {
    await pumpBanner(tester, const SessionState(status: SessionStatus.reconnecting, attempt: 2));
    expect(find.text('Reconnecting... (attempt 2 of 5)'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('failed shows the message; Retry and Disconnect reach the session', (tester) async {
    final stub = await pumpBanner(tester, const SessionState(
      status: SessionStatus.failed,
      error: DockerError(DockerErrorKind.unauthorized, 'Host key changed - reconnect from the Connections screen to review it'),
    ));
    expect(find.textContaining('Host key changed'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(stub.retries, 1);
    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(stub.disconnects, 1);
  });

  testWidgets('on a narrow screen a long failure message gets three full-width lines above the buttons', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final stub = await pumpBanner(tester, const SessionState(
      status: SessionStatus.failed,
      error: DockerError(DockerErrorKind.network, 'short'),
    ));
    final lineHeight = tester.getSize(find.text('short')).height;

    final message = 'Cannot reach the daemon: ${'no route to host, ' * 12}giving up'; // longer than any clipped error
    stub.setState(SessionState(status: SessionStatus.failed, error: DockerError(DockerErrorKind.network, message)));
    await tester.pump();
    final text = tester.getRect(find.text(message));
    final retry = tester.getRect(find.widgetWithText(TextButton, 'Retry'));
    final disconnect = tester.getRect(find.widgetWithText(TextButton, 'Disconnect'));

    // The message has the strip's width to itself (icon and paddings aside) and stops after three lines.
    expect(text.width, 360 - 16 - 24 - 12 - 8 - 8);
    expect(text.height, closeTo(3 * lineHeight, 0.5));
    expect(tester.getRect(find.byIcon(Icons.cloud_off)).top, text.top);
    // The buttons sit in a row of their own underneath, at the right edge.
    expect(retry.top, greaterThanOrEqualTo(text.bottom));
    expect(disconnect.top, retry.top);
    expect(retry.right, lessThanOrEqualTo(disconnect.left));
    expect(disconnect.right, 360 - 8);
    expect(tester.getSize(find.byType(SessionBanner)).height, lessThan(150));

    final scheme = Theme.of(tester.element(find.byType(SessionBanner))).colorScheme;
    for (final label in ['Retry', 'Disconnect']) {
      final style = tester.widget<TextButton>(find.widgetWithText(TextButton, label)).style!;
      expect(style.foregroundColor!.resolve(<WidgetState>{}), scheme.onErrorContainer, reason: label);
    }
    // Both actions are on screen and work.
    await tester.tap(find.text('Retry'));
    expect(stub.retries, 1);
    expect(find.text('Disconnect').hitTestable(), findsOneWidget);
  });

  testWidgets('the failed strip without an error reads Connection lost', (tester) async {
    await pumpBanner(tester, const SessionState(status: SessionStatus.failed));
    expect(find.text('Connection lost'), findsOneWidget);
  });

  testWidgets('the banner shows nothing while disconnected, connecting or connected', (tester) async {
    final stub = await pumpBanner(tester, const SessionState(status: SessionStatus.failed));
    expect(tester.getSize(find.byType(SessionBanner)).height, greaterThan(0));
    for (final status in [SessionStatus.disconnected, SessionStatus.connecting, SessionStatus.connected]) {
      stub.setState(SessionState(status: status));
      await tester.pump();
      expect(tester.getSize(find.byType(SessionBanner)), Size.zero, reason: status.name);
      expect(
        find.descendant(of: find.byType(SessionBanner), matching: find.byType(Text)),
        findsNothing,
        reason: status.name,
      );
    }
  });

  testWidgets('the reconnecting strip offers Disconnect, which reaches the session', (tester) async {
    final stub = await pumpBanner(tester, const SessionState(status: SessionStatus.reconnecting, attempt: 1));
    final button = find.widgetWithText(TextButton, 'Disconnect');
    expect(button, findsOneWidget);
    expect(find.text('Retry'), findsNothing); // the session is already retrying
    final scheme = Theme.of(tester.element(button)).colorScheme;
    expect(
      tester.widget<TextButton>(button).style!.foregroundColor!.resolve(<WidgetState>{}),
      scheme.onSecondaryContainer,
    );
    // The strip is only as tall as the button needs.
    expect(tester.getSize(find.byType(SessionBanner)).height, tester.getSize(button).height + 4);

    await tester.tap(button);
    await tester.pump();
    expect(stub.disconnects, 1);
    expect(stub.retries, 0);
  });

  testWidgets('showsFor says for every status whether the banner draws anything', (tester) async {
    final stub = await pumpBanner(tester, const SessionState());
    for (final status in SessionStatus.values) {
      stub.setState(SessionState(status: status, attempt: 1));
      await tester.pump();
      final drawn = tester.getSize(find.byType(SessionBanner)).height > 0;
      expect(SessionBanner.showsFor(status), drawn, reason: status.name);
    }
  });

  testWidgets('the host shows the banner above a pushed route and Disconnect pops to the first route', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final stub = StubSession(const SessionState(
      status: SessionStatus.failed,
      error: DockerError(DockerErrorKind.network, 'Cannot reach the daemon: refused'),
    ));
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWith((ref) => stub)],
      child: MaterialApp(
        navigatorKey: key,
        builder: (context, child) => SessionBannerHost(navigatorKey: key, child: child!),
        home: const Scaffold(body: Text('first')),
      ),
    ));
    key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('second'))));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);

    // The banner is not part of any route, so the pushed one cannot cover it.
    expect(find.text('Cannot reach the daemon: refused'), findsOneWidget);
    expect(find.text('Retry').hitTestable(), findsOneWidget);
    expect(
      tester.getTopLeft(find.widgetWithText(Scaffold, 'second')).dy,
      tester.getBottomLeft(find.byType(SessionBanner)).dy,
    );

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);
    expect(stub.disconnects, 1);
  });

  testWidgets('through the host the reconnecting strip disconnects from a pushed route too', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final stub = StubSession(const SessionState(status: SessionStatus.reconnecting, attempt: 1));
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWith((ref) => stub)],
      child: MaterialApp(
        navigatorKey: key,
        builder: (context, child) => SessionBannerHost(navigatorKey: key, child: child!),
        home: const Scaffold(body: Text('first')),
      ),
    ));
    key.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('second'))));
    await pumpTransition(tester);
    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);

    await tester.tap(find.text('Disconnect'));
    await pumpTransition(tester);
    expect(find.text('first'), findsOneWidget);
    expect(find.text('second'), findsNothing);
    expect(stub.disconnects, 1);
  });

  testWidgets('routes lose the top inset only while the banner shows', (tester) async {
    final key = GlobalKey<NavigatorState>();
    final stub = StubSession(const SessionState(status: SessionStatus.reconnecting, attempt: 1));
    await tester.pumpWidget(ProviderScope(
      overrides: [sessionProvider.overrideWith((ref) => stub)],
      child: MaterialApp(
        navigatorKey: key,
        // A 24 px status bar, reported above the host as the device does.
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(padding: const EdgeInsets.only(top: 24)),
          child: SessionBannerHost(navigatorKey: key, child: child!),
        ),
        home: Builder(
          builder: (context) => Scaffold(body: Text('top inset ${MediaQuery.of(context).padding.top}')),
        ),
      ),
    ));
    expect(find.text('top inset 0.0'), findsOneWidget); // the banner already sits under the status bar

    stub.setState(const SessionState(status: SessionStatus.connected));
    await tester.pump();
    expect(find.text('top inset 24.0'), findsOneWidget);

    stub.setState(const SessionState(status: SessionStatus.failed));
    await tester.pump();
    expect(find.text('top inset 0.0'), findsOneWidget);
  });
}
