import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';

import '../support/fake_session.dart';

void main() {
  test('a container event refreshes the list through the real session without errors', () {
    fakeAsync((async) {
      final errors = <Object>[];
      final d = FakeDaemon();
      d.transport.onGet(RegExp(r'/containers/json'), (_) => http.Response('[]', 200));
      late ProviderContainer c;
      int listCalls() => d.transport.calls.where((call) => call.path.endsWith('/containers/json')).length;

      // The session, its events stream and its refresh timers all start in
      // this zone: whatever one of them throws with nobody waiting for it
      // lands in [errors].
      runZonedGuarded(() {
        c = ProviderContainer(overrides: [
          transportFactoryProvider.overrideWithValue(FakeTransportFactory([d.transport])),
          lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
          profileStoreProvider.overrideWithValue(InMemoryProfileStore()),
        ]);
        c.listen(containersProvider, (_, _) {});
        c.read(sessionProvider.notifier).connect(const ConnectionProfile(
            id: '1', name: 'A', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://h:1', token: 't')));
      }, (e, _) => errors.add(e));
      addTearDown(() => c.dispose());
      async.elapse(Duration.zero);
      expect(c.read(containersProvider).hasValue, isTrue);
      expect(listCalls(), 1);

      d.events.add(eventLine(type: 'container', id: 'never-seen').codeUnits);
      async.elapse(const Duration(milliseconds: 600)); // past the 500 ms debounce
      expect(errors, isEmpty);
      expect(listCalls(), 2);
      expect(c.read(containersProvider).isLoading, isFalse); // the refetch is back,
      expect(c.read(containersProvider).hasError, isFalse); // with a list
      expect(c.exists(containerDetailProvider('never-seen')), isFalse);
      expect(d.transport.calls.where((call) => call.path.contains('/containers/never-seen/json')), isEmpty);
    });
  });
}
