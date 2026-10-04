import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/models/docker_container.dart';
import 'package:docker_mobile/src/session/events_hub.dart';
import 'package:docker_mobile/src/state/providers.dart';

final _invalidatorProvider = Provider((ref) => ProviderInvalidator(ref));

void main() {
  test('list(container) re-runs the container list', () async {
    var runs = 0;
    final c = ProviderContainer(overrides: [
      containersProvider.overrideWith((ref) async {
        runs++;
        return const <DockerContainer>[];
      }),
    ]);
    addTearDown(c.dispose);
    c.listen(containersProvider, (_, _) {});
    await c.read(containersProvider.future);
    c.read(_invalidatorProvider).list(EventCategory.container);
    await c.read(containersProvider.future);
    expect(runs, 2);
  });

  test('detail(container, id) re-runs only that container detail', () async {
    final runs = <String>[];
    final c = ProviderContainer(overrides: [
      containerDetailProvider.overrideWith((ref, id) async {
        runs.add(id);
        throw UnimplementedError();
      }),
    ]);
    addTearDown(c.dispose);
    c.listen(containerDetailProvider('a'), (_, _) {});
    c.listen(containerDetailProvider('b'), (_, _) {});
    await pumpEventQueue();
    c.read(_invalidatorProvider).detail(EventCategory.container, 'a');
    c.read(containerDetailProvider('a'));
    await pumpEventQueue();
    expect(runs.where((id) => id == 'a'), hasLength(2));
    expect(runs.where((id) => id == 'b'), hasLength(1));
  });

  test('dashboard() re-runs the system dashboard and other categories are no-ops', () async {
    var runs = 0;
    final c = ProviderContainer(overrides: [
      systemDashboardProvider.overrideWith((ref) async {
        runs++;
        throw UnimplementedError();
      }),
    ]);
    addTearDown(c.dispose);
    c.listen(systemDashboardProvider, (_, _) {});
    await pumpEventQueue();
    final inv = c.read(_invalidatorProvider)
      ..list(EventCategory.other)
      ..detail(EventCategory.network, 'n')
      ..dashboard();
    expect(inv, isNotNull);
    c.read(systemDashboardProvider);
    await pumpEventQueue();
    expect(runs, 2);
  });
}
