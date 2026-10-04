import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';

import '../support/fake_session.dart';

void main() {
  test('a container event refreshes the list through the real session without errors', () async {
    final errors = <Object>[];
    final done = Completer<void>();
    final d = FakeDaemon();
    d.transport.onGet(RegExp(r'/containers/json'), (_) => http.Response('[]', 200));
    late ProviderContainer c;
    int listCalls() => d.transport.calls.where((call) => call.path.endsWith('/containers/json')).length;

    runZonedGuarded(() async {
      c = ProviderContainer(overrides: [
        transportFactoryProvider.overrideWithValue(FakeTransportFactory([d.transport])),
        lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
        profileStoreProvider.overrideWithValue(InMemoryProfileStore()),
      ]);
      c.listen(containersProvider, (_, _) {});
      await c.read(sessionProvider.notifier).connect(const ConnectionProfile(
          id: '1', name: 'A', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://h:1', token: 't')));
      await c.read(containersProvider.future);
      expect(listCalls(), 1);

      d.events.add(eventLine(type: 'container', id: 'never-seen').codeUnits);
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await c.read(containersProvider.future);
      done.complete();
    }, (e, _) {
      errors.add(e);
      if (!done.isCompleted) done.complete();
    });
    await done.future;
    addTearDown(() => c.dispose());

    expect(errors, isEmpty);
    expect(listCalls(), 2);
    expect(c.exists(containerDetailProvider('never-seen')), isFalse);
    expect(d.transport.calls.where((call) => call.path.contains('/containers/never-seen/json')), isEmpty);
  });
}
