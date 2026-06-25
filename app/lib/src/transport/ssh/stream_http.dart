import 'dart:async';
import 'dart:convert';

class StreamHttpException implements Exception {
  final String message;
  const StreamHttpException(this.message);
  @override
  String toString() => 'StreamHttpException: $message';
}

/// Serializes an HTTP/1.1 request onto a duplex via [add]. Deterministic header
/// order (caller headers in insertion order, Content-Length last) for testing.
void writeHttpRequest(
  void Function(List<int>) add, {
  required String method,
  required String path,
  Map<String, String>? headers,
  List<int>? body,
}) {
  final sb = StringBuffer()
    ..write('$method $path HTTP/1.1\r\n')
    ..write('Host: docker\r\n');
  final h = <String, String>{...?headers};
  if (body != null) h['Content-Length'] = '${body.length}';
  h.forEach((k, v) => sb.write('$k: $v\r\n'));
  sb.write('\r\n');
  add(ascii.encode(sb.toString()));
  if (body != null && body.isNotEmpty) add(body);
}

class StreamHttpResponse {
  final int statusCode;
  final Map<String, String> headers;
  final Stream<List<int>> body;
  StreamHttpResponse({required this.statusCode, required this.headers, required this.body});
  bool get isUpgrade => statusCode == 101;
}

/// Parses status line + headers, then frames the body by Content-Length /
/// chunked / 101-upgrade-raw / read-until-close.
Future<StreamHttpResponse> readHttpResponse(Stream<List<int>> input) async {
  final reader = _ByteReader(input);
  final head = await reader.readUntil(const [13, 10, 13, 10]); // CRLF CRLF
  if (head == null) throw const StreamHttpException('truncated response head');
  final lines = ascii.decode(head).split('\r\n')..removeWhere((l) => l.isEmpty);
  final parts = lines.first.split(' ');
  if (parts.length < 2) throw const StreamHttpException('bad status line');
  final statusCode = int.tryParse(parts[1]) ?? (throw const StreamHttpException('bad status code'));
  final headers = <String, String>{};
  for (final line in lines.skip(1)) {
    final i = line.indexOf(':');
    if (i > 0) headers[line.substring(0, i).trim().toLowerCase()] = line.substring(i + 1).trim();
  }
  if (statusCode == 101) {
    return StreamHttpResponse(statusCode: 101, headers: headers, body: reader.remaining());
  }
  final te = headers['transfer-encoding'];
  if (te != null && te.toLowerCase().contains('chunked')) {
    return StreamHttpResponse(statusCode: statusCode, headers: headers, body: _dechunk(reader));
  }
  final cl = headers['content-length'];
  if (cl != null) {
    final n = int.tryParse(cl) ?? (throw const StreamHttpException('bad content-length'));
    return StreamHttpResponse(statusCode: statusCode, headers: headers, body: reader.take(n));
  }
  return StreamHttpResponse(statusCode: statusCode, headers: headers, body: reader.remaining());
}

Future<({int statusCode, Map<String, String> headers, List<int> body})> readBufferedResponse(
    Stream<List<int>> input) async {
  final resp = await readHttpResponse(input);
  final body = <int>[];
  await for (final c in resp.body) {
    body.addAll(c);
  }
  return (statusCode: resp.statusCode, headers: resp.headers, body: body);
}

Stream<List<int>> _dechunk(_ByteReader reader) async* {
  while (true) {
    final sizeLine = await reader.readLine();
    final size = int.parse(sizeLine.split(';').first.trim(), radix: 16);
    if (size == 0) {
      await reader.readLine(); // final CRLF (no trailers from dockerd)
      return;
    }
    yield* reader.take(size);
    await reader.readLine(); // CRLF after the chunk data
  }
}

/// On-demand byte reader with an internal buffer over a single subscription.
class _ByteReader {
  final StreamIterator<List<int>> _it;
  final List<int> _buf = [];
  bool _done = false;
  _ByteReader(Stream<List<int>> source) : _it = StreamIterator(source);

  Future<bool> _fill() async {
    if (_done) return false;
    if (await _it.moveNext()) {
      _buf.addAll(_it.current);
      return true;
    }
    _done = true;
    return false;
  }

  Future<List<int>?> readUntil(List<int> pattern) async {
    var search = 0;
    while (true) {
      final idx = _indexOf(_buf, pattern, search);
      if (idx != -1) {
        final end = idx + pattern.length;
        final out = _buf.sublist(0, end);
        _buf.removeRange(0, end);
        return out;
      }
      search = (_buf.length - pattern.length + 1).clamp(0, _buf.length);
      if (!await _fill()) return null;
    }
  }

  Future<String> readLine() async {
    final bytes = await readUntil(const [13, 10]);
    if (bytes == null) throw const StreamHttpException('unexpected end of stream (line)');
    return ascii.decode(bytes.sublist(0, bytes.length - 2));
  }

  Stream<List<int>> take(int n) async* {
    var remaining = n;
    while (remaining > 0) {
      if (_buf.isEmpty && !await _fill()) {
        throw const StreamHttpException('unexpected end of body');
      }
      final t = remaining < _buf.length ? remaining : _buf.length;
      yield _buf.sublist(0, t);
      _buf.removeRange(0, t);
      remaining -= t;
    }
  }

  Stream<List<int>> remaining() async* {
    if (_buf.isNotEmpty) {
      yield List<int>.from(_buf);
      _buf.clear();
    }
    while (await _fill()) {
      if (_buf.isNotEmpty) {
        yield List<int>.from(_buf);
        _buf.clear();
      }
    }
  }
}

int _indexOf(List<int> hay, List<int> needle, int start) {
  outer:
  for (var i = start < 0 ? 0 : start; i <= hay.length - needle.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return i;
  }
  return -1;
}
