import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/api/stdcopy.dart';

/// Builds a stdcopy frame: [type, 0,0,0, len(4, big-endian), ...payload].
List<int> frame(int type, List<int> payload) {
  final n = payload.length;
  return [type, 0, 0, 0, (n >> 24) & 0xff, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff, ...payload];
}

Future<List<LogChunk>> collect(List<List<int>> chunks) =>
    decodeStdcopy(Stream.fromIterable(chunks)).toList();

void main() {
  test('decodes a single stdout frame', () async {
    final out = await collect([frame(1, [104, 105])]); // "hi"
    expect(out, hasLength(1));
    expect(out.single.source, LogStream.stdout);
    expect(out.single.bytes, [104, 105]);
  });

  test('decodes stdout then stderr in one chunk', () async {
    final out = await collect([
      [...frame(1, [97]), ...frame(2, [98])],
    ]);
    expect(out.map((c) => c.source).toList(), [LogStream.stdout, LogStream.stderr]);
    expect(out.map((c) => c.bytes.single).toList(), [97, 98]);
  });

  test('reassembles a header split across two chunks', () async {
    final f = frame(1, [120, 121]); // 10 bytes total (8 header + 2 payload)
    final out = await collect([f.sublist(0, 3), f.sublist(3)]);
    expect(out.single.bytes, [120, 121]);
  });

  test('reassembles a payload split across two chunks', () async {
    final f = frame(2, [1, 2, 3, 4]);
    final out = await collect([f.sublist(0, 9), f.sublist(9)]); // split mid-payload
    expect(out.single.source, LogStream.stderr);
    expect(out.single.bytes, [1, 2, 3, 4]);
  });

  test('emits nothing for a trailing partial frame', () async {
    final out = await collect([
      [...frame(1, [1]), 1, 0, 0], // a full frame + 3 dangling header bytes
    ]);
    expect(out, hasLength(1));
    expect(out.single.bytes, [1]);
  });

  test('handles an empty payload frame', () async {
    final out = await collect([frame(1, [])]);
    expect(out.single.bytes, isEmpty);
    expect(out.single.source, LogStream.stdout);
  });

  test('does not throw on a malformed stream type', () async {
    // type 7 is invalid; decoder must recover (emit remaining as stderr) not throw.
    final out = await collect([
      [7, 0, 0, 0, 0, 0, 0, 1, 65],
    ]);
    expect(out, isNotEmpty);
    expect(out.first.source, LogStream.stderr);
  });

  test('raw decoder passes each chunk through as stdout', () async {
    final out = await decodeRawLog(Stream.fromIterable([
      [104, 105],
      [10],
    ])).toList();
    expect(out, hasLength(2));
    expect(out.every((c) => c.source == LogStream.stdout), isTrue);
    expect(out[0].bytes, [104, 105]);
  });
}
