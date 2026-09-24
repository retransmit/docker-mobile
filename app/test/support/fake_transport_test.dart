import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'fake_transport.dart';

void main() {
  test('exact path rule answers and records the call', () async {
    final t = FakeTransport()..onGet('/containers/json', (_) => http.Response('[]', 200));
    final r = await t.get('/containers/json', query: {'all': 'true'});
    expect(r.statusCode, 200);
    expect(t.lastPath, '/containers/json');
    expect(t.lastQuery, {'all': 'true'});
    expect(t.calls.single.method, 'GET');
  });

  test('regex rule, last registered wins, unmatched is 404', () async {
    final t = FakeTransport()
      ..onPost(RegExp(r'/exec$'), (_) => http.Response('{"Id":"e1"}', 201))
      ..onPost(RegExp(r'/exec$'), (_) => http.Response('{"Id":"e2"}', 201));
    expect((await t.post('/containers/x/exec')).body, '{"Id":"e2"}');
    expect((await t.delete('/nothing')).statusCode, 404);
  });

  test('throwOn throws for buffered calls and errors for streams', () async {
    final t = FakeTransport()
      ..throwOn('GET', RegExp('.*'), const SocketException('refused'))
      ..throwOn('STREAM', '/events', const SocketException('gone'));
    expect(t.get('/x'), throwsA(isA<SocketException>()));
    expect(t.stream('/events').first, throwsA(isA<SocketException>()));
  });

  test('hangOn never completes', () async {
    final t = FakeTransport()..hangOn('GET', '/slow');
    var done = false;
    t.get('/slow').then((_) => done = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(done, isFalse);
  });

  test('execAttach hands out FakeExecChannels and close is recorded', () async {
    final t = FakeTransport();
    final ch = await t.execAttach('e1', cols: 80, rows: 24) as FakeExecChannel;
    ch.send([1]);
    expect(t.lastChannel.sent, [[1]]);
    expect(t.calls.single.query, {'cols': '80', 'rows': '24'});
    await t.close();
    expect(t.closed, isTrue);
  });
}
