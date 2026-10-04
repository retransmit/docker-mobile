import 'dart:io';

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

  test('`all` refreshes each resource provider and creates none', () async {
    var lists = 0;
    final details = <String>[];
    final c = ProviderContainer(overrides: [
      containersProvider.overrideWith((ref) async {
        lists++;
        return const <DockerContainer>[];
      }),
      containerDetailProvider.overrideWith((ref, id) async {
        details.add(id);
        throw UnimplementedError();
      }),
    ]);
    addTearDown(c.dispose);
    await c.read(containersProvider.future);
    c.read(containerDetailProvider('a'));
    await pumpEventQueue();
    expect(lists, 1);
    expect(details, ['a']);

    c.read(_invalidatorProvider).all();
    await c.read(containersProvider.future);
    c.read(containerDetailProvider('a'));
    await pumpEventQueue();
    expect(lists, 2);
    expect(details, ['a', 'a']);
    // Nothing is created for a provider or a family member that was never read.
    expect(c.exists(imagesProvider), isFalse);
    expect(c.exists(containerDetailProvider('b')), isFalse);
  });

  test('every provider that uses resourceClient is listed in resourceProviders', () {
    // A provider that takes its client from resourceClient is refreshed after a
    // reconnect only if `all` knows it. Count the calls in the sources (tests
    // run with the package root as the working directory).
    final call = RegExp(r'\bresourceClient\(');
    final declaration = RegExp(r'^DockerApiClient resourceClient\(', multiLine: true);
    final callsByFile = <String, int>{};
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final source = entity.readAsStringSync();
      final calls = call.allMatches(source).length - declaration.allMatches(source).length;
      if (calls > 0) callsByFile[entity.path.replaceAll(r'\', '/')] = calls;
    }
    expect(callsByFile.keys, ['lib/src/state/providers.dart'], reason: 'resource providers live next to the list');
    expect(callsByFile['lib/src/state/providers.dart'], resourceProviders.length,
        reason: 'calls of resourceClient versus entries in resourceProviders');
  });
}
