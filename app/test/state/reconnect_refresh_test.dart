import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/session/reconnect_policy.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';

import '../support/fake_session.dart';

const _profileA = ConnectionProfile(
    id: '1', name: 'A', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://a:1', token: 't'));
const _profileB = ConnectionProfile(
    id: '2', name: 'B', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://b:1', token: 't'));

const _oneContainer = '[{"Id":"c1","Names":["/web"],"Image":"nginx","State":"running","Status":"Up"}]';

/// A container over the real session. The session takes [daemons] in order:
/// the first on connect, the next on every reconnect or new connection.
/// Reconnects are immediate unless [policy] says otherwise.
ProviderContainer _container(List<FakeDaemon> daemons, {ReconnectPolicy? policy}) {
  final c = ProviderContainer(overrides: [
    transportFactoryProvider.overrideWithValue(FakeTransportFactory([for (final d in daemons) d.transport])),
    reconnectPolicyProvider.overrideWithValue(policy ?? immediatePolicy()),
    lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
    profileStoreProvider.overrideWithValue(InMemoryProfileStore()),
  ]);
  addTearDown(c.dispose);
  return c;
}

/// Breaks [daemon]'s events stream, so the session reconnects through the next daemon.
Future<void> _dropConnection(FakeDaemon daemon) async {
  daemon.events.addError(const DockerError(DockerErrorKind.network, 'reset'));
  await pumpEventQueue();
}

/// How many GETs [daemon] received on a path ending in [suffix].
int _gets(FakeDaemon daemon, String suffix) =>
    daemon.transport.calls.where((call) => call.method == 'GET' && call.path.endsWith(suffix)).length;

/// What a screen's `when` (with its defaults) shows for [value].
String _shown(AsyncValue<Object?> value) =>
    value.when(data: (_) => 'data', error: (_, _) => 'error', loading: () => 'loading');

/// [_shown], with a refresh in flight marked.
String _phase(AsyncValue<Object?> value) => '${_shown(value)}${value.isRefreshing ? ', refreshing' : ''}';

/// A daemon that answers every resource endpoint the tests read.
FakeDaemon _fullDaemon() {
  final d = FakeDaemon();
  d.transport
    ..onGet(RegExp(r'/containers/json$'), (_) => http.Response(_oneContainer, 200))
    ..onGet(RegExp(r'/containers/(c1|c2|idle)/json$'), (_) => http.Response('{"Id":"c"}', 200))
    ..onGet(RegExp(r'/images/json$'), (_) => http.Response('[]', 200))
    ..onGet(RegExp(r'/images/i1/json$'), (_) => http.Response('{"Id":"i1"}', 200))
    ..onGet(RegExp(r'/images/i1/history$'), (_) => http.Response('[]', 200))
    ..onGet(RegExp(r'/networks$'), (_) => http.Response('[]', 200))
    ..onGet(RegExp(r'/networks/n1$'), (_) => http.Response('{"Id":"n1"}', 200))
    ..onGet(RegExp(r'/volumes$'), (_) => http.Response('{"Volumes":[]}', 200))
    ..onGet(RegExp(r'/volumes/v1$'), (_) => http.Response('{"Name":"v1"}', 200))
    ..onGet(RegExp(r'/info$'), (_) => http.Response('{}', 200))
    ..onGet(RegExp(r'/system/df$'), (_) => http.Response('{}', 200));
  return d;
}

void main() {
  test('a reconnect refreshes the list in place: the old data stays until the new arrives', () async {
    final d1 = FakeDaemon(), d2 = FakeDaemon();
    d1.transport.onGet(RegExp(r'/containers/json$'), (_) => http.Response(_oneContainer, 200));
    d2.transport.hangOn('GET', RegExp(r'/containers/json'));
    final c = _container([d1, d2]);
    c.listen(containersProvider, (_, _) {});
    await c.read(sessionProvider.notifier).connect(_profileA);
    await c.read(containersProvider.future);

    await _dropConnection(d1);

    expect(c.read(sessionProvider).transport, same(d2.transport));
    final v = c.read(containersProvider);
    expect(v.isRefreshing, isTrue, reason: 'a refresh keeps the data on screen; the state is $v');
    expect(v.isReloading, isFalse);
    expect(v.requireValue, hasLength(1));
    expect(_shown(v), 'data');
    expect(_gets(d2, '/containers/json'), 1);
  });

  test('every reconnect refreshes in place, not only the first', () async {
    final daemons = [for (var i = 0; i < 4; i++) FakeDaemon()];
    for (final d in daemons) {
      d.transport.onGet(RegExp(r'/containers/json$'), (_) => http.Response(_oneContainer, 200));
    }
    final c = _container(daemons);
    final seen = <String>[];
    c.listen(containersProvider, (_, next) => seen.add(_phase(next)));
    await c.read(sessionProvider.notifier).connect(_profileA);
    await c.read(containersProvider.future);
    seen.clear();

    for (var i = 1; i < daemons.length; i++) {
      await _dropConnection(daemons[i - 1]);
      final why = 'reconnect $i';
      expect(c.read(sessionProvider).transport, same(daemons[i].transport), reason: why);
      expect(_gets(daemons[i], '/containers/json'), 1, reason: why);
      // The transport that was replaced is not asked again.
      expect(_gets(daemons[i - 1], '/containers/json'), 1, reason: why);
      expect(seen, ['data, refreshing', 'data'], reason: why);
      seen.clear();
    }
  });

  test('a new connection reloads: nothing from the previous daemon is shown', () async {
    final d1 = FakeDaemon(), d2 = FakeDaemon();
    d1.transport.onGet(RegExp(r'/containers/json$'), (_) => http.Response(_oneContainer, 200));
    d2.transport.hangOn('GET', RegExp(r'/containers/json'));
    final c = _container([d1, d2]);
    c.listen(containersProvider, (_, _) {});
    await c.read(sessionProvider.notifier).connect(_profileA);
    await c.read(containersProvider.future);
    expect(c.read(containersProvider).requireValue, hasLength(1));

    await c.read(sessionProvider.notifier).connect(_profileB);
    await pumpEventQueue();

    expect(c.read(sessionProvider).transport, same(d2.transport));
    final v = c.read(containersProvider);
    expect(v.isLoading, isTrue, reason: 'the new daemon has not answered yet; the state is $v');
    expect(v.isRefreshing, isFalse);
    expect(_shown(v), 'loading');
    expect(_gets(d2, '/containers/json'), 1);
  });

  test('a provider nobody listens to reloads on its next read after a new connection', () async {
    final d1 = FakeDaemon(), d2 = FakeDaemon();
    d1.transport.onGet(RegExp(r'/containers/json$'), (_) => http.Response(_oneContainer, 200));
    d2.transport.hangOn('GET', RegExp(r'/containers/json'));
    final c = _container([d1, d2]);
    final session = c.read(sessionProvider.notifier);
    await session.connect(_profileA);
    expect(await c.read(containersProvider.future), hasLength(1));

    await session.disconnect();
    await session.connect(_profileB);
    await pumpEventQueue();
    expect(c.read(sessionProvider).transport, same(d2.transport));
    // Nobody listens, so the new connection alone fetches nothing.
    expect(_gets(d2, '/containers/json'), 0);

    final v = c.read(containersProvider);
    expect(_shown(v), 'loading', reason: 'the state is $v');
    expect(_gets(d2, '/containers/json'), 1);
  });

  test('a refresh pending when the connection is lost never runs: the list stays up until the reconnect', () {
    fakeAsync((async) {
      final d1 = FakeDaemon(), d2 = FakeDaemon();
      for (final d in [d1, d2]) {
        d.transport.onGet(RegExp(r'/containers/json$'), (_) => http.Response(_oneContainer, 200));
      }
      // The first retry comes well after the refresh debounce (0.5 s).
      final c = _container([d1, d2], policy: ReconnectPolicy(base: const Duration(seconds: 5), jitter: 0));
      final seen = <String>[];
      c.listen(containersProvider, (_, next) => seen.add(_phase(next)));
      c.read(sessionProvider.notifier).connect(_profileA);
      async.elapse(Duration.zero);
      expect(_shown(c.read(containersProvider)), 'data');
      seen.clear();

      // A container dies and the daemon goes away right after it said so.
      d1.transport.throwOn('GET', RegExp(r'/containers/json$'), const DockerError(DockerErrorKind.network, 'down'));
      d1.events.add(utf8.encode(eventLine(action: 'die', timeNano: 1700000000000000123)));
      async.flushMicrotasks();
      d1.events.addError(const DockerError(DockerErrorKind.network, 'reset'));
      async.flushMicrotasks();
      expect(c.read(sessionProvider).status, SessionStatus.reconnecting);

      async.elapse(const Duration(seconds: 3));
      expect(c.read(sessionProvider).status, SessionStatus.reconnecting);
      expect(seen, isEmpty, reason: 'nothing may be asked of the dead connection');
      expect(_shown(c.read(containersProvider)), 'data');
      expect(_gets(d1, '/containers/json'), 1);

      async.elapse(const Duration(seconds: 3));
      expect(c.read(sessionProvider).transport, same(d2.transport));
      expect(seen, ['data, refreshing', 'data']);
      expect(_gets(d2, '/containers/json'), 1);
      expect(_gets(d1, '/containers/json'), 1);
    });
  });

  test('a reconnect refreshes every resource provider that is listened to and builds none that is not', () async {
    final d1 = _fullDaemon(), d2 = _fullDaemon();
    final c = _container([d1, d2]);
    // Every resource provider, with an endpoint only it reads.
    final listened = <ProviderListenable<Object?>, String>{
      containersProvider: '/containers/json',
      containerDetailProvider('c1'): '/containers/c1/json',
      containerInspectProvider('c2'): '/containers/c2/json',
      imagesProvider: '/images/json',
      imageDetailProvider('i1'): '/images/i1/json',
      imageHistoryProvider('i1'): '/images/i1/history',
      networksProvider: '/networks',
      networkDetailProvider('n1'): '/networks/n1',
      volumesProvider: '/volumes',
      volumeDetailProvider('v1'): '/volumes/v1',
      systemDashboardProvider: '/info',
    };
    final seen = {for (final endpoint in listened.values) endpoint: <String>[]};
    listened.forEach((provider, endpoint) {
      c.listen<Object?>(provider, (_, next) => seen[endpoint]!.add(_phase(next as AsyncValue<Object?>)));
    });
    await c.read(sessionProvider.notifier).connect(_profileA);
    // Read once and then left alone: nothing listens to it.
    await c.read(containerDetailProvider('idle').future);
    await pumpEventQueue();
    for (final endpoint in listened.values) {
      expect(_gets(d1, endpoint), 1, reason: 'the first load of $endpoint');
      expect(seen[endpoint]!.last, 'data', reason: 'the first load of $endpoint');
      seen[endpoint]!.clear();
    }

    await _dropConnection(d1);

    expect(c.read(sessionProvider).transport, same(d2.transport));
    for (final endpoint in listened.values) {
      expect(_gets(d2, endpoint), 1, reason: 'the refetch of $endpoint');
      expect(seen[endpoint], ['data, refreshing', 'data'], reason: 'what $endpoint shows meanwhile');
    }
    // The dashboard's other two calls (the session's probe asks for /version too).
    expect(_gets(d2, '/system/df'), 1);
    expect(_gets(d2, '/version'), 2);
    // Nothing is fetched for a provider that nobody listens to, seen before or not.
    expect(_gets(d2, '/containers/idle/json'), 0);
    expect(c.exists(containerDetailProvider('never-seen')), isFalse);
  });
}
