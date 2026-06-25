import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/ssh/stream_http.dart';

void main() {
  test('writeHttpRequest serializes a GET with no body', () {
    final out = <int>[];
    writeHttpRequest(out.addAll, method: 'GET', path: '/version');
    expect(ascii.decode(out), 'GET /version HTTP/1.1\r\nHost: docker\r\n\r\n');
  });

  test('writeHttpRequest serializes a POST with a JSON body + Content-Length', () {
    final out = <int>[];
    final body = utf8.encode('{"k":"v"}');
    writeHttpRequest(out.addAll, method: 'POST', path: '/x',
        headers: {'Content-Type': 'application/json'}, body: body);
    final text = ascii.decode(out);
    expect(text.startsWith('POST /x HTTP/1.1\r\nHost: docker\r\n'), isTrue);
    expect(text.contains('Content-Type: application/json\r\n'), isTrue);
    expect(text.contains('Content-Length: 9\r\n'), isTrue);
    expect(text.endsWith('\r\n\r\n{"k":"v"}'), isTrue);
  });

  test('readHttpResponse frames a Content-Length body', () async {
    final bytes = ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}');
    final resp = await readHttpResponse(Stream.value(bytes));
    expect(resp.statusCode, 200);
    expect(resp.isUpgrade, isFalse);
    final body = await resp.body.expand((c) => c).toList();
    expect(utf8.decode(body), '{}');
  });

  test('readHttpResponse de-chunks a body split across input events', () async {
    // chunk "hello" (5) split mid-data across two stream events, then terminator.
    final events = <List<int>>[
      ascii.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhe'),
      ascii.encode('llo\r\n0\r\n\r\n'),
    ];
    final resp = await readHttpResponse(Stream.fromIterable(events));
    final body = await resp.body.expand((c) => c).toList();
    expect(utf8.decode(body), 'hello');
  });

  test('readHttpResponse detects a 101 upgrade and passes raw remainder', () async {
    final bytes = ascii.encode('HTTP/1.1 101 UPGRADED\r\nUpgrade: tcp\r\n\r\nRAW');
    final resp = await readHttpResponse(Stream.value(bytes));
    expect(resp.isUpgrade, isTrue);
    final raw = await resp.body.expand((c) => c).toList();
    expect(utf8.decode(raw), 'RAW');
  });

  test('readHttpResponse throws on a truncated head', () async {
    final bytes = ascii.encode('HTTP/1.1 200 OK\r\nContent-Le');
    expect(readHttpResponse(Stream.value(bytes)), throwsA(isA<StreamHttpException>()));
  });

  test('readBufferedResponse returns status, headers, and full body', () async {
    final bytes = ascii.encode('HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nno!');
    final r = await readBufferedResponse(Stream.value(bytes));
    expect(r.statusCode, 404);
    expect(r.headers['content-length'], '3');
    expect(utf8.decode(r.body), 'no!');
  });
}
