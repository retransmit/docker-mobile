import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';

import '../support/fake_transport.dart';

/// Opens [open] against a transport whose stream never emits, cancels it
/// while it is idle, and reports whether the transport stream saw the cancel.
Future<bool> cancelReachesSource(Stream<Object?> Function(DockerApiClient c) open, {bool post = false}) async {
  var cancelled = false;
  final source = StreamController<List<int>>(onCancel: () => cancelled = true);
  final t = FakeTransport();
  if (post) {
    t.onPostStream(RegExp('.*'), (_) => source.stream);
  } else {
    t.onStream(RegExp('.*'), (_) => source.stream);
  }
  final sub = open(DockerApiClient(t)).listen((_) {});
  await pumpEventQueue();
  unawaited(sub.cancel());
  await pumpEventQueue();
  return cancelled;
}

void main() {
  test('cancelling an idle events stream cancels the transport stream', () async {
    expect(await cancelReachesSource((c) => c.streamEvents()), isTrue);
  });

  test('cancelling an idle stats stream cancels the transport stream', () async {
    expect(await cancelReachesSource((c) => c.streamContainerStats('a')), isTrue);
  });

  test('cancelling an idle non-TTY logs stream cancels the transport stream', () async {
    expect(await cancelReachesSource((c) => c.streamContainerLogs('a', tty: false)), isTrue);
  });

  test('cancelling an idle TTY logs stream cancels the transport stream', () async {
    expect(await cancelReachesSource((c) => c.streamContainerLogs('a', tty: true)), isTrue);
  });

  test('cancelling an idle pull cancels the transport stream', () async {
    expect(await cancelReachesSource((c) => c.pullImage('nginx'), post: true), isTrue);
  });

  test('decodeStdcopy forwards a cancel to its input', () async {
    var cancelled = false;
    final input = StreamController<List<int>>(onCancel: () => cancelled = true);
    final sub = decodeStdcopy(input.stream).listen((_) {});
    await pumpEventQueue();
    unawaited(sub.cancel());
    await pumpEventQueue();
    expect(cancelled, isTrue);
  });

  test('an event split mid-character across chunks still decodes', () async {
    final bytes = utf8.encode('{"Type":"container","Action":"start","Actor":{"ID":"c1","Attributes":{"name":"caf\u00e9"}}}\n');
    final cut = bytes.length - 5; // inside the trailing JSON, after the two-byte e-acute
    final split = bytes.indexOf(0xA9); // second byte of e-acute (0xC3 0xA9)
    final t = FakeTransport()
      ..onStream(RegExp('.*'), (_) => Stream.fromIterable([bytes.sublist(0, split), bytes.sublist(split, cut), bytes.sublist(cut)]));
    final events = await DockerApiClient(t).streamEvents().toList();
    expect(events.single.target, 'caf\u00e9');
  });

  test('blank and malformed NDJSON lines are skipped, a trailing unterminated pull line is kept', () async {
    final t = FakeTransport()
      ..onPostStream(RegExp('.*'), (_) => Stream.value(utf8.encode('\n{not json}\n{"status":"Pulling"}\n{"status":"Done"}')));
    final events = await DockerApiClient(t).pullImage('nginx').toList();
    expect(events.map((e) => e.status), ['Pulling', 'Done']);
  });
}
