import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_error.dart';
import 'package:docker_mobile/src/api/timestamps.dart';
import 'package:docker_mobile/src/state/logs_notifier.dart';
import 'package:docker_mobile/src/state/providers.dart';
import 'package:docker_mobile/src/state/stats_notifier.dart';
import 'package:docker_mobile/src/storage/credential_store.dart';
import 'package:docker_mobile/src/storage/profile_store.dart';

import '../support/fake_session.dart';

void main() {
  test('after every reconnect logs and stats reopen once, on the new transport, from the cursor', () async {
    final daemons = [for (var i = 0; i < 4; i++) FakeContainerDaemon()];
    final c = ProviderContainer(overrides: [
      transportFactoryProvider.overrideWithValue(FakeTransportFactory([for (final d in daemons) d.transport])),
      reconnectPolicyProvider.overrideWithValue(immediatePolicy()),
      lifecycleSourceProvider.overrideWithValue(ManualLifecycleSource()),
      profileStoreProvider.overrideWithValue(InMemoryProfileStore()),
    ]);
    addTearDown(c.dispose);
    await c.read(sessionProvider.notifier).connect(const ConnectionProfile(
        id: '1', name: 'A', kind: ConnectionKind.agent, agent: AgentCredentials(baseUri: 'http://h:1', token: 't')));
    const key = (id: 'a', tty: true); // a TTY, so log bytes are sent unframed
    c.listen(logsProvider(key), (_, _) {});
    c.listen(statsProvider('a'), (_, _) {});
    await pumpEventQueue();
    expect(daemons.first.logOpens, hasLength(1));
    expect(daemons.first.statsOpens, hasLength(1));

    daemons.first.logs.add(utf8.encode('$firstLogStamp first\n'));
    await pumpEventQueue();
    expect(c.read(logsProvider(key)).lines.single.text, 'first');

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
    expect(c.read(logsProvider(key)).lines.map((l) => l.text), ['first', 'second']);
  });
}
