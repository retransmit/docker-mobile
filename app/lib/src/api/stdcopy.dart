import 'dart:async';
import 'dart:typed_data';

/// Upper bound on a single stdcopy frame's declared payload length. A header
/// claiming more than this is treated as malformed, so a corrupt length can't
/// make the decoder buffer unboundedly while "waiting for more bytes".
const int _maxFrameLen = 64 * 1024 * 1024;

enum LogStream { stdout, stderr }

class LogChunk {
  final LogStream source;
  final List<int> bytes;
  const LogChunk(this.source, this.bytes);
}

/// Decodes Docker's stdcopy multiplexed stream (used for non-TTY containers):
/// repeating `[type, 0,0,0, len(uint32 big-endian), ...payload]` frames.
/// Reassembles frames split across input chunks; never throws on bad input.
/// Built as a transformer, so cancelling the result cancels [input] at once.
Stream<LogChunk> decodeStdcopy(Stream<List<int>> input) {
  var acc = Uint8List(0);
  return input.transform(StreamTransformer<List<int>, LogChunk>.fromHandlers(
    handleData: (chunk, sink) {
      if (chunk.isEmpty) return;
      final merged = Uint8List(acc.length + chunk.length)
        ..setRange(0, acc.length, acc)
        ..setRange(acc.length, acc.length + chunk.length, chunk);
      acc = merged;

      var offset = 0;
      while (acc.length - offset >= 8) {
        final type = acc[offset];
        if (type > 2) {
          // Malformed/desynced: surface the rest defensively and stop parsing.
          sink.add(LogChunk(LogStream.stderr, acc.sublist(offset)));
          offset = acc.length;
          break;
        }
        final len = (acc[offset + 4] << 24) |
            (acc[offset + 5] << 16) |
            (acc[offset + 6] << 8) |
            acc[offset + 7];
        if (len > _maxFrameLen) {
          // Implausible length => corrupt header; surface the rest and stop.
          sink.add(LogChunk(LogStream.stderr, acc.sublist(offset)));
          offset = acc.length;
          break;
        }
        if (acc.length - offset - 8 < len) break; // need more bytes
        final payload = acc.sublist(offset + 8, offset + 8 + len);
        sink.add(LogChunk(type == 2 ? LogStream.stderr : LogStream.stdout, payload));
        offset += 8 + len;
      }
      acc = offset == 0 ? acc : acc.sublist(offset);
    },
  ));
}

/// TTY passthrough: TTY containers emit a single un-framed stream.
Stream<LogChunk> decodeRawLog(Stream<List<int>> input) =>
    input.map((chunk) => LogChunk(LogStream.stdout, chunk));
