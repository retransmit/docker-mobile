import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/api/timestamps.dart';
import 'package:docker_mobile/src/session/session_state.dart';
import 'package:docker_mobile/src/state/logs_notifier.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/state/stats_notifier.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';
import 'package:docker_mobile/src/transport/transport.dart';

import '../support/fake_session.dart';

const _profileA = ConnectionProfile(
    id: '1', name: 'A', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://a:1', token: 't'));
const _profileB = ConnectionProfile(
    id: '2', name: 'B', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://b:1', token: 't'));

/// The logs of container `a`: a TTY, so log bytes are sent unframed.
const _logs = (id: 'a', tty: true);

/// A container over the real session. The session takes [transports] in
/// order: the first on connect, the next on every reconnect or new
/// connection. A future of a transport holds that connection open until it
/// completes.
ProviderContainer _container(List<Object> transports) {
  final c = ProviderContainer(overrides: [
    transportFactoryProvider.overrideWithValue(FakeTransportFactory(transports)),
    reconnectPolicyProvider.overrideWithValue(immediatePolicy()),
    lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
    profileStoreProvider.overrideWithValue(InMemoryProfileStore()),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('after every reconnect logs and stats reopen once, on the new transport, from the cursor', () async {
    final daemons = [for (var i = 0; i < 4; i++) FakeContainerDaemon()];
    final c = _container([for (final d in daemons) d.transport]);
    await c.read(sessionProvider.notifier).connect(_profileA);
    c.listen(logsProvider(_logs), (_, _) {});
    c.listen(statsProvider('a'), (_, _) {});
    await pumpEventQueue();
    expect(daemons.first.logOpens, hasLength(1));
    expect(daemons.first.statsOpens, hasLength(1));

    daemons.first.logs.add(utf8.encode('$firstLogStamp first\n'));
    await pumpEventQueue();
    expect(c.read(logsProvider(_logs)).lines.single.text, 'first');

    for (var i = 1; i < daemons.length; i++) {
      final old = daemons[i - 1], current = daemons[i];
      old.events.addError(const DockerError(DockerErrorKind.network, 'reset'));
      await pumpEventQueue();

      final why = 'reconnect $i';
      expect(c.read(sessionProvider).transport, same(current.transport), reason: why);
      expect(current.logOpens, hasLength(1), reason: why);
      expect(current.statsOpens, hasLength(1), reason: why);
      expect(current.logOpens.single.query!['since'], rfc3339ToUnixNanos(firstLogStamp), reason: why);
      // The transport that was replaced is not used again.
      expect(old.logOpens, hasLength(1), reason: why);
      expect(old.statsOpens, hasLength(1), reason: why);
    }

    daemons.last.logs.add(utf8.encode('$secondLogStamp second\n'));
    await pumpEventQueue();
    expect(c.read(logsProvider(_logs)).lines.map((l) => l.text), ['first', 'second']);
  });

  test('a new connection gives a fresh stream on the new transport', () async {
    final d1 = FakeContainerDaemon(), d2 = FakeContainerDaemon();
    final handshake = Completer<Transport>(); // keeps the second connection in `connecting`
    final c = _container([d1.transport, handshake.future]);
    final session = c.read(sessionProvider.notifier);
    await session.connect(_profileA);
    c.listen(logsProvider(_logs), (_, _) {});
    c.listen(statsProvider('a'), (_, _) {});
    await pumpEventQueue();
    d1.logs.add(utf8.encode('$firstLogStamp first\n'));
    await pumpEventQueue();
    expect(c.read(logsProvider(_logs)).lines.single.text, 'first');

    final connected = session.connect(_profileB);
    await pumpEventQueue(); // the stream providers rebuild while there is no client yet
    expect(c.read(sessionProvider).status, SessionStatus.connecting);
    handshake.complete(d2.transport);
    await connected;
    await pumpEventQueue();

    expect(c.read(sessionProvider).transport, same(d2.transport));
    expect(d2.logOpens, hasLength(1));
    expect(d2.logOpens.single.query!.containsKey('since'), isFalse);
    expect(d2.statsOpens, hasLength(1));
    // Nothing of the first daemon is left, and the new streams are running.
    expect(c.read(logsProvider(_logs)).lines, isEmpty);
    expect(c.read(logsProvider(_logs)).status, LogsStatus.streaming);
    expect(c.read(statsProvider('a')).status, StatsStatus.loading);
  });

  test('a new connection while the logs are paused starts over without an error', () async {
    final d1 = FakeContainerDaemon(), d2 = FakeContainerDaemon();
    final c = _container([d1.transport, d2.transport]);
    final session = c.read(sessionProvider.notifier);
    await session.connect(_profileA);
    c.listen(logsProvider(_logs), (_, _) {});
    await pumpEventQueue();
    c.read(logsProvider(_logs).notifier).setFollowing(false);

    // The provider is rebuilt for the new connection, yet its old session
    // listener still hears this update, after the notifier was disposed. An
    // error thrown there is uncaught and fails the test.
    await session.connect(_profileB);
    await pumpEventQueue();

    expect(d2.logOpens, hasLength(1));
    expect(c.read(logsProvider(_logs)).following, isTrue);
    expect(c.read(logsProvider(_logs)).status, LogsStatus.streaming);
  });
}
