import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/api/timestamps.dart';
import 'package:docker_mobile/src/session/reconnect_policy.dart';
import 'package:docker_mobile/src/state/logs_notifier.dart';
import 'package:docker_mobile/src/state/providers.dart';

import '../support/fake_transport.dart';

/// Streams [chunks] afresh on every subscription (Stream.fromIterable is
/// multi-listen), so re-subscribing (follow/tail/timestamps changes) works.
FakeTransport chunksFake(List<List<int>> chunks) =>
    FakeTransport.streaming(Stream.fromIterable(chunks));

List<int> frame(int type, List<int> payload) {
  final n = payload.length;
  return [type, 0, 0, 0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, ...payload];
}

void main() {
  test('assembles lines across chunk boundaries', () async {
    final client = DockerApiClient(chunksFake([
      frame(1, utf8.encode('hel')),
      frame(1, utf8.encode('lo\nwor')),
      frame(1, utf8.encode('ld\n')),
    ]));
    final n = LogsNotifier(() => client, 'a', false);
    await pumpEventQueue();
    expect(n.state.lines.map((l) => l.text).toList(), ['hello', 'world']);
    n.dispose();
  });

  test('tags stderr lines', () async {
    final client = DockerApiClient(chunksFake([frame(2, utf8.encode('boom\n'))]));
    final n = LogsNotifier(() => client, 'a', false);
    await pumpEventQueue();
    expect(n.state.lines.single.source, LogStream.stderr);
    n.dispose();
  });

  test('search filters visible lines', () async {
    final client = DockerApiClient(chunksFake([frame(1, utf8.encode('apple\nbanana\n'))]));
    final n = LogsNotifier(() => client, 'a', false);
    await pumpEventQueue();
    n.setSearch('ban');
    expect(n.state.visibleLines.map((l) => l.text).toList(), ['banana']);
    n.dispose();
  });

  test('caps the buffer at kLogBufferCap lines', () async {
    final many = '${List.generate(kLogBufferCap + 10, (i) => 'line$i').join('\n')}\n';
    final client = DockerApiClient(chunksFake([frame(1, utf8.encode(many))]));
    final n = LogsNotifier(() => client, 'a', false);
    await pumpEventQueue();
    expect(n.state.lines.length, kLogBufferCap);
    expect(n.state.lines.last.text, 'line${kLogBufferCap + 9}'); // newest kept
    n.dispose();
  });

  test('reaches idle status when a non-following stream completes', () async {
    final client = DockerApiClient(chunksFake([frame(1, utf8.encode('x\n'))]));
    final n = LogsNotifier(() => client, 'a', false);
    await pumpEventQueue();
    expect(n.state.status, LogsStatus.idle);
    n.dispose();
  });

  test('pause stops the live stream and preserves buffered lines', () async {
    final controller = StreamController<List<int>>();
    final client = DockerApiClient(FakeTransport.streaming(controller.stream));
    final n = LogsNotifier(() => client, 'a', false);

    controller.add(frame(1, utf8.encode('one\n')));
    await pumpEventQueue();
    expect(n.state.lines.map((l) => l.text).toList(), ['one']);

    n.setFollowing(false);
    await pumpEventQueue();
    expect(n.state.status, LogsStatus.paused);
    expect(n.state.lines.map((l) => l.text).toList(), ['one']); // NOT cleared

    // Bytes after pause must not appear (subscription was canceled).
    controller.add(frame(1, utf8.encode('two\n')));
    await pumpEventQueue();
    expect(n.state.lines.map((l) => l.text).toList(), ['one']);

    n.dispose();
    await controller.close();
  });

  test('enters error status and preserves lines on stream error', () async {
    final controller = StreamController<List<int>>();
    final client = DockerApiClient(FakeTransport.streaming(controller.stream));
    final n = LogsNotifier(() => client, 'a', false);

    controller.add(frame(1, utf8.encode('before\n')));
    await pumpEventQueue();
    controller.addError(Exception('boom'));
    await pumpEventQueue();

    expect(n.state.status, LogsStatus.error);
    expect(n.state.error, contains('boom'));
    expect(n.state.lines.map((l) => l.text).toList(), ['before']); // preserved

    n.dispose();
    await controller.close();
  });

  test('logsProvider is autoDispose: notifier is disposed when the last listener leaves', () async {
    final controller = StreamController<List<int>>();
    final container = ProviderContainer(overrides: [
      dockerClientProvider.overrideWith((ref) => DockerApiClient(FakeTransport.streaming(controller.stream))),
    ]);
    addTearDown(container.dispose);

    const key = (id: 'a', tty: false);
    final sub = container.listen(logsProvider(key), (_, _) {});
    final notifier = container.read(logsProvider(key).notifier);

    controller.add(frame(1, utf8.encode('one\n')));
    await pumpEventQueue();
    expect(notifier.state.lines.single.text, 'one');
    expect(notifier.mounted, isTrue); // live while listened to

    // Removing the only listener must auto-dispose the notifier. Its dispose()
    // cancels the live log-stream subscription, so no leaked follow stream
    // survives the LogsScreen being popped.
    sub.close();
    await pumpEventQueue();
    expect(notifier.mounted, isFalse);

    await controller.close();
  });

  test('parses the leading RFC3339 timestamp when timestamps enabled', () async {
    final line = '2026-01-02T03:04:05.000000000Z hello\n';
    final client = DockerApiClient(chunksFake([frame(1, utf8.encode(line))]));
    final n = LogsNotifier(() => client, 'a', false);
    n.setTimestamps(true); // display-only: the daemon always sends them
    await pumpEventQueue();

    final l = n.state.lines.single;
    expect(l.text, 'hello');
    expect(l.timestamp, isNotNull);
    expect(l.timestamp!.toUtc(), DateTime.utc(2026, 1, 2, 3, 4, 5));
    n.dispose();
  });

  String ts(int nanos) => '2026-01-02T03:04:05.${nanos.toString().padLeft(9, '0')}Z';
  final base = DateTime.utc(2026, 1, 2, 3, 4, 5).millisecondsSinceEpoch ~/ 1000 * 1000000000;

  test('always asks the daemon for timestamps; the toggle is display-only', () async {
    final t = chunksFake([frame(1, utf8.encode('${ts(1)} one\n'))]);
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();
    expect(t.lastQuery!['timestamps'], 'true');
    final opens = t.calls.where((c) => c.method == 'STREAM').length;
    n.setTimestamps(true);
    n.setTimestamps(false);
    await pumpEventQueue();
    expect(t.calls.where((c) => c.method == 'STREAM').length, opens);
    expect(n.state.lines.single.text, 'one');
    expect(n.state.lines.single.rawTimestamp, ts(1));
    n.dispose();
  });

  test('a retryable error reopens from the cursor and drops the repeated boundary line', () {
    fakeAsync((async) {
      final controllers = <StreamController<List<int>>>[];
      final t = FakeTransport()
        ..onStream('/containers/a/logs', (_) {
          final c = StreamController<List<int>>();
          controllers.add(c);
          return c.stream;
        });
      final n = LogsNotifier(() => DockerApiClient(t), 'a', false, policy: ReconnectPolicy(jitter: 0));
      async.flushMicrotasks();
      controllers.last.add(frame(1, utf8.encode('${ts(1)} one\n')));
      async.flushMicrotasks();
      controllers.last.addError(const DockerError(DockerErrorKind.network, 'reset'));
      async.flushMicrotasks();
      expect(n.state.status, LogsStatus.reconnecting);
      async.elapse(const Duration(seconds: 1));
      final q = t.calls.where((c) => c.method == 'STREAM').last.query!;
      expect(q['since'], formatUnixNanos(base + 1));
      expect(q['tail'], 'all');
      controllers.last.add(frame(1, utf8.encode('${ts(1)} one\n${ts(2)} two\n')));
      async.flushMicrotasks();
      expect(n.state.lines.map((l) => l.text), ['one', 'two']);
      expect(n.state.status, LogsStatus.streaming);
      n.dispose();
    });
  });

  test('setLive(false) pauses as reconnecting; setLive(true) resumes from the cursor', () {
    fakeAsync((async) {
      final controllers = <StreamController<List<int>>>[];
      var cancelled = 0;
      final t = FakeTransport()
        ..onStream('/containers/a/logs', (_) {
          final c = StreamController<List<int>>(onCancel: () => cancelled++);
          controllers.add(c);
          return c.stream;
        });
      final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
      async.flushMicrotasks();
      controllers.last.add(frame(1, utf8.encode('${ts(5)} five\n')));
      async.flushMicrotasks();
      n.setLive(false);
      async.flushMicrotasks();
      expect(cancelled, 1);
      expect(n.state.status, LogsStatus.reconnecting);
      n.setLive(true);
      expect(controllers, hasLength(2));
      expect(t.calls.where((c) => c.method == 'STREAM').last.query!['since'], formatUnixNanos(base + 5));
      n.dispose();
    });
  });

  test('a user pause while not live stays paused when the session comes back', () {
    fakeAsync((async) {
      final t = FakeTransport()..onStream('/containers/a/logs', (_) => StreamController<List<int>>().stream);
      final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
      async.flushMicrotasks();
      n.setFollowing(false);
      n.setLive(false);
      n.setLive(true);
      async.flushMicrotasks();
      expect(n.state.status, LogsStatus.paused);
      expect(t.calls.where((c) => c.method == 'STREAM'), hasLength(1));
      n.dispose();
    });
  });

  test('a stream that ends cleanly settles on idle without reopening', () {
    fakeAsync((async) {
      final t = chunksFake([frame(1, utf8.encode('${ts(1)} only\n'))]);
      final n = LogsNotifier(() => DockerApiClient(t), 'a', false, policy: ReconnectPolicy(jitter: 0));
      async.flushMicrotasks();
      async.elapse(const Duration(minutes: 1));
      expect(n.state.status, LogsStatus.idle);
      expect(t.calls.where((c) => c.method == 'STREAM'), hasLength(1));
      n.dispose();
    });
  });

  test('setTail starts over without a cursor', () async {
    final t = chunksFake([frame(1, utf8.encode('${ts(1)} one\n'))]);
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();
    n.setTail(100);
    await pumpEventQueue();
    final q = t.calls.where((c) => c.method == 'STREAM').last.query!;
    expect(q['tail'], '100');
    expect(q.containsKey('since'), isFalse);
    expect(n.state.lines.single.text, 'one');
    n.dispose();
  });

  /// A log stream that ends after one line on every open: open n sends the
  /// line stamped ts(n).
  FakeTransport endingFake() {
    var count = 0;
    return FakeTransport()
      ..onStream('/containers/a/logs', (_) {
        count++;
        return Stream.value(frame(1, utf8.encode('${ts(count)} line$count\n')));
      });
  }

  test('play after the stream ended reopens it from the cursor', () async {
    final t = endingFake();
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();
    expect(n.state.status, LogsStatus.idle);
    expect(n.state.lines.map((l) => l.text), ['line1']);

    n.setFollowing(false);
    n.setFollowing(true);
    await pumpEventQueue();

    final opens = t.calls.where((c) => c.method == 'STREAM').toList();
    expect(opens, hasLength(2));
    expect(opens.last.query!['since'], formatUnixNanos(base + 1));
    expect(n.state.lines.map((l) => l.text), ['line1', 'line2']);
    n.dispose();
  });

  test('the session coming back reopens a stream that had ended', () async {
    final t = endingFake();
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();
    expect(n.state.status, LogsStatus.idle);

    n.setLive(false);
    n.setLive(true);
    await pumpEventQueue();

    final opens = t.calls.where((c) => c.method == 'STREAM').toList();
    expect(opens, hasLength(2));
    expect(opens.last.query!['since'], formatUnixNanos(base + 1));
    expect(n.state.lines.map((l) => l.text), ['line1', 'line2']);
    n.dispose();
  });

  test('setTail while paused refetches the tail once without follow', () async {
    final lines = frame(1, utf8.encode('${ts(1)} one\n${ts(2)} two\n'));
    final t = FakeTransport()
      ..onStream('/containers/a/logs', (call) {
        // Like the daemon: a follow stays open, a one-off fetch ends.
        if (call.query!['follow'] == 'true') return (StreamController<List<int>>()..add(lines)).stream;
        return Stream.value(lines);
      });
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();
    expect(n.state.lines.map((l) => l.text), ['one', 'two']);

    n.setFollowing(false);
    expect(n.state.status, LogsStatus.paused);
    n.setTail(100);
    await pumpEventQueue();

    final opens = t.calls.where((c) => c.method == 'STREAM').toList();
    expect(opens, hasLength(2)); // the follow, then one refetch
    final q = opens.last.query!;
    expect(q['tail'], '100');
    expect(q.containsKey('since'), isFalse);
    expect(q['follow'], 'false');
    expect(n.state.lines.map((l) => l.text), ['one', 'two']);
    expect(n.state.following, isFalse);
    expect(n.state.status, LogsStatus.idle);
    n.dispose();
  });

  /// A log stream whose first open fails with a 404 (not retryable); every
  /// later open sends one line and ends.
  FakeTransport failingOnceFake() {
    var count = 0;
    return FakeTransport()
      ..onStream('/containers/a/logs', (_) {
        count++;
        if (count == 1) return Stream.error(DockerError.fromResponse(404, '{"message":"gone"}'));
        return Stream.value(frame(1, utf8.encode('${ts(1)} back\n')));
      });
  }

  test('play after the stream failed reopens it', () async {
    final t = failingOnceFake();
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();
    expect(n.state.status, LogsStatus.error);

    n.setFollowing(false);
    n.setFollowing(true);
    await pumpEventQueue();

    expect(t.calls.where((c) => c.method == 'STREAM'), hasLength(2));
    expect(n.state.lines.map((l) => l.text), ['back']);
    expect(n.state.status, LogsStatus.idle);
    n.dispose();
  });

  test('the session coming back reopens a stream that had failed', () async {
    final t = failingOnceFake();
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();
    expect(n.state.status, LogsStatus.error);

    n.setLive(false);
    n.setLive(true);
    await pumpEventQueue();

    expect(t.calls.where((c) => c.method == 'STREAM'), hasLength(2));
    expect(n.state.lines.map((l) => l.text), ['back']);
    expect(n.state.status, LogsStatus.idle);
    n.dispose();
  });

  test('play during a one-off fetch starts following', () async {
    final t = FakeTransport()..onStream('/containers/a/logs', (_) => StreamController<List<int>>().stream);
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();

    n.setFollowing(false);
    n.setTail(100); // a one-off fetch, still open
    n.setFollowing(true);
    await pumpEventQueue();

    final opens = t.calls.where((c) => c.method == 'STREAM').toList();
    expect(opens.last.query!['follow'], 'true');
    expect(opens.last.query!['tail'], '100');
    expect(opens, hasLength(3)); // the first follow, the one-off fetch, the follow that replaces it
    expect(n.state.status, LogsStatus.streaming);
    n.dispose();
  });

  test('a tail change while paused and away is fetched when the session returns', () async {
    final t = FakeTransport()..onStream('/containers/a/logs', (_) => StreamController<List<int>>().stream);
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();
    List<RecordedCall> opens() => t.calls.where((c) => c.method == 'STREAM').toList();

    n.setFollowing(false);
    n.setLive(false);
    n.setTail(100);
    await pumpEventQueue();
    expect(opens(), hasLength(1)); // nothing is fetched while the session is away

    n.setLive(true);
    await pumpEventQueue();
    expect(opens(), hasLength(2));
    final q = opens().last.query!;
    expect(q['tail'], '100');
    expect(q['follow'], 'false');
    expect(q.containsKey('since'), isFalse);
    expect(n.state.following, isFalse);
    n.dispose();
  });

  test('a one-off fetch cut short by the session is made up from the cursor', () async {
    final controllers = <StreamController<List<int>>>[];
    final t = FakeTransport()
      ..onStream('/containers/a/logs', (_) {
        final c = StreamController<List<int>>();
        controllers.add(c);
        return c.stream;
      });
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();
    List<RecordedCall> opens() => t.calls.where((c) => c.method == 'STREAM').toList();

    n.setFollowing(false);
    n.setTail(100); // the one-off fetch
    controllers.last.add(frame(1, utf8.encode('${ts(7)} seven\n')));
    await pumpEventQueue();
    expect(n.state.lines.single.text, 'seven');

    n.setLive(false); // the session drops before the fetch is done
    n.setLive(true);
    await pumpEventQueue();

    expect(opens(), hasLength(3));
    final q = opens().last.query!;
    expect(q['follow'], 'false');
    expect(q['since'], formatUnixNanos(base + 7));
    expect(n.state.following, isFalse);
    n.dispose();
  });

  test('retry is ignored while the session is away', () async {
    final t = FakeTransport()..onStream('/containers/a/logs', (_) => StreamController<List<int>>().stream);
    final n = LogsNotifier(() => DockerApiClient(t), 'a', false);
    await pumpEventQueue();
    List<RecordedCall> opens() => t.calls.where((c) => c.method == 'STREAM').toList();

    n.setLive(false);
    n.retry();
    await pumpEventQueue();
    expect(opens(), hasLength(1));
    expect(n.state.status, LogsStatus.reconnecting);

    n.setLive(true); // the stream restarts by itself
    n.retry(); // and Retry works again
    await pumpEventQueue();
    expect(opens(), hasLength(3));
    n.dispose();
  });
}
