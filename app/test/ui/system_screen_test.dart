import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/ui/system_screen.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';

class _FakeTransport implements Transport {
  @override
  Future<void> close() async {}
  final List<String> posts = [];
  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async {
    if (path == '/info') {
      return http.Response('{"ServerVersion":"27.0.3","OSType":"linux","Architecture":"x86_64","NCPU":8,"MemTotal":16000000000,"Driver":"overlay2","Containers":5,"ContainersRunning":3,"Images":12}', 200);
    }
    if (path == '/version') return http.Response('{"Version":"27.0.3","ApiVersion":"1.46","Arch":"amd64","Os":"linux"}', 200);
    if (path == '/system/df') return http.Response('{"Images":[{"Size":104857600}],"Containers":[],"Volumes":[],"BuildCache":[]}', 200);
    return http.Response('{}', 200);
  }
  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    posts.add(path);
    return http.Response('', 200);
  }
  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) async => http.Response('', 204);
  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();
  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();
  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) => const Stream.empty();
}

void main() {
  testWidgets('renders daemon + disk usage', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: SystemScreen()),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(StatCard), findsNWidgets(4)); // containers/images/volumes/disk grid
    expect(find.widgetWithText(StatCard, 'Containers'), findsOneWidget);
    expect(find.widgetWithText(StatCard, 'Images'), findsOneWidget);
    expect(find.widgetWithText(StatCard, '3'), findsOneWidget); // containersRunning value
    expect(find.textContaining('27.0.3'), findsWidgets); // server version
    expect(find.textContaining('overlay2'), findsWidgets); // storage driver

    // a disk-usage size renders in monospace
    await tester.scrollUntilVisible(find.text('Total'), 200,
        scrollable: find.byType(Scrollable).first);
    expect(find.byType(MonoText), findsWidgets);
    final sizeText = tester.widget<Text>(
        find.descendant(of: find.byType(MonoText), matching: find.byType(Text)).first);
    expect(sizeText.style?.fontFamily, 'monospace');
  });

  testWidgets('System prune with both toggles runs the full sequence', (tester) async {
    final t = _FakeTransport();
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: const MaterialApp(home: SystemScreen()),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(ElevatedButton, 'System prune'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    // Toggle both switches on.
    await tester.tap(find.widgetWithText(SwitchListTile, 'All unused images'));
    await tester.tap(find.widgetWithText(SwitchListTile, 'Also unused volumes'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Prune'));
    await tester.pumpAndSettle();

    expect(t.posts, containsAll(<String>['/containers/prune', '/networks/prune', '/images/prune', '/build/prune', '/volumes/prune']));
  });

  testWidgets('Disconnect action confirms then nulls the transport', (tester) async {
    final t = _FakeTransport();
    late ProviderContainer container;
    await tester.pumpWidget(ProviderScope(
      overrides: [transportProvider.overrideWith((ref) => t)],
      child: MaterialApp(
        home: Builder(builder: (ctx) {
          container = ProviderScope.containerOf(ctx);
          return Scaffold(
            body: Center(child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).push(
                  MaterialPageRoute(builder: (_) => const SystemScreen())),
              child: const Text('open'),
            )),
          );
        }),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();
    expect(find.text('Disconnect from this daemon?'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(container.read(transportProvider), isNull);
    expect(find.text('open'), findsOneWidget); // popped back
  });
}
