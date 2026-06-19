import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:docker_mobile/main.dart';

void main() {
  testWidgets('app boots to the connection screen', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: DockerMobileApp()));
    expect(find.text('Connect to agent'), findsOneWidget);
    expect(find.text('Connect'), findsWidgets);
  });
}
