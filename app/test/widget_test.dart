import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/main.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/ui/profiles_screen.dart';

void main() {
  testWidgets('app boots to the profiles screen', (tester) async {
    // Override the store with an in-memory fake so the boot test never touches
    // real platform secure storage (which would hang the loading spinner).
    await tester.pumpWidget(
      ProviderScope(
        overrides: [profileStoreProvider.overrideWithValue(InMemoryProfileStore())],
        child: const DockerMobileApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ProfilesScreen), findsOneWidget);
  });
}
