import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/main.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/state/theme_provider.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/storage/settings_store.dart';
import 'package:docker_mobile/src/ui/profiles_screen.dart';
import 'package:docker_mobile/src/ui/settings_screen.dart';
import 'package:docker_mobile/src/ui/widgets/session_banner.dart';

import 'support/stub_session.dart';

/// Boots the whole app on in-memory stores (see the boot test), plus [overrides].
Future<void> _pumpApp(WidgetTester tester, {List<Override> overrides = const []}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        profileStoreProvider.overrideWithValue(InMemoryProfileStore()),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        ...overrides,
      ],
      child: const DockerMobileApp(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('app boots to the profiles screen', (tester) async {
    // Override the stores with in-memory fakes so the boot test never touches
    // real platform secure storage (which would hang the loading spinner and,
    // for settings, surface a MissingPluginException as an uncaught async error).
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          profileStoreProvider.overrideWithValue(InMemoryProfileStore()),
          settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        ],
        child: const DockerMobileApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProfilesScreen), findsOneWidget);
  });

  testWidgets('the app puts the session banner host above its routes', (tester) async {
    await _pumpApp(tester);
    expect(find.byType(SessionBannerHost), findsOneWidget);
    // Above the navigator: the first route (and so every route) sits inside it.
    expect(
      find.ancestor(of: find.byType(ProfilesScreen), matching: find.byType(SessionBannerHost)),
      findsOneWidget,
    );
  });

  testWidgets('the app banner disconnects through the app navigator', (tester) async {
    final stub = StubSession(const SessionState(status: SessionStatus.failed));
    await _pumpApp(tester, overrides: [sessionProvider.overrideWith((ref) => stub)]);
    await tester.tap(find.byTooltip('Settings'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsOneWidget);
    expect(find.text('Retry').hitTestable(), findsOneWidget); // still there over a pushed route

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsScreen), findsNothing);
    expect(find.byType(ProfilesScreen), findsOneWidget);
    expect(stub.disconnects, 1);
  });
}
