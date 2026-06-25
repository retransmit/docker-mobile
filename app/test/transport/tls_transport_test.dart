import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/transport/tls_transport.dart';

/// Records the last request and returns a programmed streamed response.
class _FakeClient extends http.BaseClient {
  http.BaseRequest? last;
  String? lastBody;
  int status = 200;
  List<int> respBody = const [];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    last = request;
    if (request is http.Request) lastBody = request.body;
    return http.StreamedResponse(Stream.value(respBody), status, request: request);
  }
}

void main() {
  final base = Uri.parse('https://10.0.0.5:2376');

  test('get builds the URI with no Authorization header', () async {
    final c = _FakeClient()..respBody = utf8.encode('[]');
    final t = TlsTransport(baseUri: base, client: c);
    await t.get('/containers/json', query: {'all': 'true'});
    expect(c.last!.method, 'GET');
    expect(c.last!.url.toString(), 'https://10.0.0.5:2376/containers/json?all=true');
    expect(c.last!.headers.containsKey('Authorization'), isFalse);
  });

  test('post JSON-encodes a map body and sets Content-Type, no auth', () async {
    final c = _FakeClient();
    final t = TlsTransport(baseUri: base, client: c);
    await t.post('/containers/x/exec', body: {'Cmd': ['sh']});
    expect(c.last!.method, 'POST');
    expect(c.lastBody, '{"Cmd":["sh"]}');
    expect((c.last!.headers['content-type'] ?? '').contains('application/json'), isTrue);
    expect(c.last!.headers.containsKey('Authorization'), isFalse);
  });

  test('delete builds the URI with query', () async {
    final c = _FakeClient();
    final t = TlsTransport(baseUri: base, client: c);
    await t.delete('/containers/x', query: {'force': 'true'});
    expect(c.last!.method, 'DELETE');
    expect(c.last!.url.query, 'force=true');
  });

  test('stream yields the response bytes and is 200-gated', () async {
    final c = _FakeClient()..respBody = utf8.encode('chunk');
    final t = TlsTransport(baseUri: base, client: c);
    final bytes = await t.stream('/containers/x/logs').first;
    expect(utf8.decode(bytes), 'chunk');
  });

  test('stream surfaces a non-200 as TransportException', () async {
    final c = _FakeClient()..status = 404..respBody = utf8.encode('no such container');
    final t = TlsTransport(baseUri: base, client: c);
    expect(t.stream('/containers/x/logs').first, throwsA(isA<TransportException>()));
  });

  test('execAttach delegates to the injected opener', () async {
    final channel = SocketExecChannel(input: const Stream.empty(), onSend: (_) {}, onClose: () async {});
    var captured = <Object>[];
    final t = TlsTransport(
      baseUri: base,
      client: _FakeClient(),
      execOpener: (id, cols, rows) async { captured = [id, cols, rows]; return channel; },
    );
    final ch = await t.execAttach('exec123', cols: 80, rows: 24);
    expect(identical(ch, channel), isTrue);
    expect(captured, ['exec123', 80, 24]);
  });

  test('SocketExecChannel forwards send, maps output, and closes once', () async {
    final sent = <List<int>>[];
    var closes = 0;
    final ch = SocketExecChannel(
      input: Stream.value(utf8.encode('out')),
      onSend: sent.add,
      onClose: () async { closes++; },
    );
    expect(utf8.decode(await ch.output.first), 'out');
    ch.send(utf8.encode('in'));
    expect(utf8.decode(sent.single), 'in');
    await ch.close();
    await ch.close(); // idempotent
    expect(closes, 1);
  });
}
