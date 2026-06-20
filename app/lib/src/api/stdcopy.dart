import 'dart:typed_data';

enum LogStream { stdout, stderr }

class LogChunk {
  final LogStream source;
  final List<int> bytes;
  const LogChunk(this.source, this.bytes);
}

/// Decodes Docker's stdcopy multiplexed stream (used for non-TTY containers):
/// repeating `[type, 0,0,0, len(uint32 big-endian), ...payload]` frames.
/// Reassembles frames split across input chunks; never throws on bad input.
Stream<LogChunk> decodeStdcopy(Stream<List<int>> input) async* {
  var acc = Uint8List(0);
  await for (final chunk in input) {
    if (chunk.isEmpty) continue;
    final merged = Uint8List(acc.length + chunk.length)
      ..setRange(0, acc.length, acc)
      ..setRange(acc.length, acc.length + chunk.length, chunk);
    acc = merged;

    var offset = 0;
    while (acc.length - offset >= 8) {
      final type = acc[offset];
      if (type > 2) {
        // Malformed/desynced: surface the rest defensively and stop parsing.
        yield LogChunk(LogStream.stderr, acc.sublist(offset));
        offset = acc.length;
        break;
      }
      final len = (acc[offset + 4] << 24) |
          (acc[offset + 5] << 16) |
          (acc[offset + 6] << 8) |
          acc[offset + 7];
      if (acc.length - offset - 8 < len) break; // need more bytes
      final payload = acc.sublist(offset + 8, offset + 8 + len);
      yield LogChunk(type == 2 ? LogStream.stderr : LogStream.stdout, payload);
      offset += 8 + len;
    }
    acc = offset == 0 ? acc : acc.sublist(offset);
  }
}

/// TTY passthrough: TTY containers emit a single un-framed stream.
Stream<LogChunk> decodeRawLog(Stream<List<int>> input) async* {
  await for (final chunk in input) {
    yield LogChunk(LogStream.stdout, chunk);
  }
}
