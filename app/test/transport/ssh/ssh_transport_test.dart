import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_connection.dart';
import 'package:docker_mobile/src/transport/ssh/ssh_transport.dart';

Duplex _duplex(List<int> response, List<int> written, {void Function()? onClose}) => Duplex(
      input: Stream.value(response),
      add: written.addAll,
      close: () async => onClose?.call(),
    );

void main() {
  test('get builds the request line + parses the response; no Authorization', () async {
    final written = <int>[];
    final t = SshTransport(openDuplex: () async =>
        _duplex(ascii.encode('HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n[]'), written));
    final resp = await t.get('/containers/json', query: {'all': 'true'});
    expect(resp.statusCode, 200);
    expect(resp.body, '[]');
    final reqText = ascii.decode(written);
    expect(reqText.contains('GET /containers/json?all=true HTTP/1.1'), isTrue);
    expect(reqText.toLowerCase().contains('authorization'), isFalse);
  });

  test('post sends a JSON body + Content-Length', () async {
    final written = <int>[];
    final t = SshTransport(openDuplex: () async =>
        _duplex(ascii.encode('HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n'), written));
    await t.post('/x', body: {'k': 'v'});
    final reqText = ascii.decode(written);
    expect(reqText.contains('POST /x HTTP/1.1'), isTrue);
    expect(reqText.contains('Content-Type: application/json'), isTrue);
    expect(reqText.endsWith('{"k":"v"}'), isTrue);
  });

  test('delete passes query', () async {
    final written = <int>[];
    final t = SshTransport(openDuplex: () async =>
        _duplex(ascii.encode('HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n'), written));
    await t.delete('/containers/x', query: {'force': 'true'});
    expect(ascii.decode(written).contains('DELETE /containers/x?force=true HTTP/1.1'), isTrue);
  });

  test('stream yields body bytes and closes the channel on cancel', () async {
    final input = StreamController<List<int>>();
    var closed = false;
    final conn = Duplex(input: input.stream, add: (_) {}, close: () async => closed = true);
    final t = SshTransport(openDuplex: () async => conn);
    final got = <int>[];
    final sub = t.stream('/c/logs').listen(got.addAll);
    input.add(ascii.encode('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n'));
    await pumpEventQueue();
    input.add(ascii.encode('5\r\nhello\r\n'));
    await pumpEventQueue();
    expect(utf8.decode(got), 'hello');
    await sub.cancel();
    expect(closed, isTrue);
    await input.close();
  });

  test('stream surfaces a non-200 as TransportException', () async {
    final t = SshTransport(openDuplex: () async =>
        _duplex(ascii.encode('HTTP/1.1 404 Not Found\r\nContent-Length: 3\r\n\r\nno!'), <int>[]));
    expect(t.stream('/c/logs').first, throwsA(isA<TransportException>()));
  });

  test('execAttach hijacks: sends Upgrade + body, output is the raw remainder', () async {
    final written = <int>[];
    final t = SshTransport(openDuplex: () async => _duplex(
        ascii.encode('HTTP/1.1 101 UPGRADED\r\nUpgrade: tcp\r\n\r\nshell-output'), written));
    final ch = await t.execAttach('exec1', cols: 80, rows: 24);
    final reqText = ascii.decode(written);
    expect(reqText.contains('POST /exec/exec1/start HTTP/1.1'), isTrue);
    expect(reqText.contains('Connection: Upgrade'), isTrue);
    expect(reqText.contains('Upgrade: tcp'), isTrue);
    expect(reqText.contains('{"Detach":false,"Tty":true}'), isTrue);
    expect(utf8.decode(await ch.output.first), 'shell-output');
  });
}
