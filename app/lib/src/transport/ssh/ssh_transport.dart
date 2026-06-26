import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../duplex_exec_channel.dart';
import '../transport.dart';
import 'ssh_connection.dart';
import 'stream_http.dart';

String _pathWithQuery(String path, Map<String, String>? query) =>
    (query == null || query.isEmpty) ? path : Uri(path: path, queryParameters: query).toString();

/// Direct Docker transport over SSH: each call opens a fresh `dial-stdio`
/// channel ([Duplex]) over a shared SSH connection. No bearer token.
class SshTransport implements Transport {
  final Future<Duplex> Function() _openDuplex;
  // ignore: prefer_initializing_formals — keep the public `openDuplex` param name.
  SshTransport({required Future<Duplex> Function() openDuplex}) : _openDuplex = openDuplex;

  Future<http.Response> _send(String method, String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    final conn = await _openDuplex();
    try {
      final h = <String, String>{...?headers};
      List<int>? bodyBytes;
      if (body != null) {
        bodyBytes = utf8.encode(body is String ? body : jsonEncode(body));
        h['Content-Type'] = 'application/json';
      }
      writeHttpRequest(conn.add,
          method: method, path: _pathWithQuery(path, query), headers: h.isEmpty ? null : h, body: bodyBytes);
      final r = await readBufferedResponse(conn.input);
      return http.Response.bytes(r.body, r.statusCode, headers: r.headers);
    } finally {
      await conn.close();
    }
  }

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) =>
      _send('GET', path, query: query);

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      _send('DELETE', path, query: query);

  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) =>
      _send('POST', path, query: query, body: body, headers: headers);

  Stream<List<int>> _openStream(String method, String path,
      {Map<String, String>? query, Object? body}) {
    final controller = StreamController<List<int>>();
    Duplex? conn;
    var cancelled = false;
    controller.onListen = () async {
      try {
        conn = await _openDuplex();
        final h = <String, String>{};
        List<int>? bodyBytes;
        if (body != null) {
          bodyBytes = utf8.encode(body is String ? body : jsonEncode(body));
          h['Content-Type'] = 'application/json';
        }
        writeHttpRequest(conn!.add,
            method: method, path: _pathWithQuery(path, query), headers: h.isEmpty ? null : h, body: bodyBytes);
        final resp = await readHttpResponse(conn!.input);
        if (resp.statusCode != 200) {
          final b = await resp.body.expand((c) => c).toList();
          controller.addError(TransportException(resp.statusCode, utf8.decode(b, allowMalformed: true)));
          await controller.close();
          await conn!.close();
          return;
        }
        // The subscription is intentionally not retained: closing the duplex
        // (onCancel / error / done) ends the source stream and completes it,
        // so there is nothing to cancel by hand.
        resp.body.listen(
          controller.add,
          // After a cancel we close the duplex; the framing reader then sees a
          // premature EOF and throws. Swallow that teardown noise.
          onError: (Object e, StackTrace st) {
            if (!cancelled) controller.addError(e, st);
          },
          onDone: () async {
            if (cancelled) return;
            await controller.close();
            await conn!.close();
          },
          cancelOnError: true,
        );
      } catch (e) {
        controller.addError(e);
        await controller.close();
        await conn?.close();
      }
    };
    controller.onCancel = () async {
      // Closing the duplex ends the underlying input stream, which completes
      // the framing reader the inner subscription is parked on (no separate
      // inner cancel needed — and awaiting one here would deadlock against a
      // reader still suspended on `moveNext`). The `cancelled` guard silences
      // the premature-EOF error that teardown then raises.
      cancelled = true;
      await conn?.close();
    };
    return controller.stream;
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) =>
      _openStream('GET', path, query: query);

  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) =>
      _openStream('POST', path, query: query, body: body);

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async {
    final conn = await _openDuplex();
    writeHttpRequest(
      conn.add,
      method: 'POST',
      path: '/exec/$execId/start',
      headers: {'Connection': 'Upgrade', 'Upgrade': 'tcp', 'Content-Type': 'application/json'},
      body: utf8.encode(jsonEncode({'Detach': false, 'Tty': true})),
    );
    final resp = await readHttpResponse(conn.input);
    return SocketExecChannel(input: resp.body, onSend: conn.add, onClose: conn.close);
  }
}
