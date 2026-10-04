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
