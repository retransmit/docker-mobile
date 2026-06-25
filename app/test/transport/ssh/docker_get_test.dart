import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';

void main() {
  test('dockerGet writes the request to the duplex and parses the response', () async {
    final written = <int>[];
    final response = ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 9\r\n\r\n{"v":"1"}');
    final conn = Duplex(
      input: Stream.value(response),
      add: written.addAll,
      close: () async {},
    );
    final r = await dockerGet(conn, '/version');
    expect(r.statusCode, 200);
    expect(utf8.decode(r.body), '{"v":"1"}');
    expect(ascii.decode(written), contains('GET /version HTTP/1.1'));
    expect(ascii.decode(written), contains('Host: docker'));
  });
}
