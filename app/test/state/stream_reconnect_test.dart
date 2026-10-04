import 'dart:async';
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
import '../support/fake_transport.dart';

/// A daemon with container `a`: every logs or stats open gets a stream that
/// stays open, and the test writes log bytes to [logs].
class _Daemon extends FakeDaemon {
  _Daemon() {
    transport
      ..onStream(RegExp(r'/containers/a/logs$'), (_) => (logs = StreamController<List<int>>()).stream)
      ..onStream(RegExp(r'/containers/a/stats$'), (_) => StreamController<List<int>>().stream);
  }

  /// The most recently opened logs stream.
  late StreamController<List<int>> logs;

  List<RecordedCall> opens(String stream) =>
      transport.calls.where((c) => c.method == 'STREAM' && c.path.endsWith('/containers/a/$stream')).toList();
}

const _first = '2026-01-02T03:04:05.000000001Z';
const _second = '2026-01-02T03:04:05.000000002Z';

void main() {
  test('after every reconnect logs and stats reopen once, on the new transport, from the cursor', () async {
    final daemons = [for (var i = 0; i < 4; i++) _Daemon()];
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
    expect(daemons.first.opens('logs'), hasLength(1));
    expect(daemons.first.opens('stats'), hasLength(1));

    daemons.first.logs.add(utf8.encode('$_first first\n'));
    await pumpEventQueue();
    expect(c.read(logsProvider(key)).lines.single.text, 'first');

    for (var i = 1; i < daemons.length; i++) {
      final old = daemons[i - 1], current = daemons[i];
      old.events.addError(const DockerError(DockerErrorKind.network, 'reset'));
      await pumpEventQueue();

      final why = 'reconnect $i';
      expect(c.read(sessionProvider).transport, same(current.transport), reason: why);
      expect(current.opens('logs'), hasLength(1), reason: why);
      expect(current.opens('stats'), hasLength(1), reason: why);
      expect(current.opens('logs').single.query!['since'], rfc3339ToUnixNanos(_first), reason: why);
      // The transport that was replaced is not used again.
      expect(old.opens('logs'), hasLength(1), reason: why);
      expect(old.opens('stats'), hasLength(1), reason: why);
    }

    daemons.last.logs.add(utf8.encode('$_second second\n'));
    await pumpEventQueue();
    expect(c.read(logsProvider(key)).lines.map((l) => l.text), ['first', 'second']);
  });
}
