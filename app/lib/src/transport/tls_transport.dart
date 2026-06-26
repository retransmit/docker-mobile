// Private fields are bound to public named constructor params (e.g. `client`),
// so an initializing formal (`this._client`) would be a private named param —
// which Dart forbids. Keep the explicit initializer-list assignment.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'duplex_exec_channel.dart';
import 'transport.dart';

export 'duplex_exec_channel.dart' show SocketExecChannel;

/// Direct mutual-TLS transport to a Docker daemon (no agent, no bearer token).
class TlsTransport implements Transport {
  final Uri baseUri;
  final http.Client _client;
  final Future<ExecChannel> Function(String execId, int cols, int rows)? _execOpener;

  TlsTransport({
    required this.baseUri,
    required http.Client client,
    Future<ExecChannel> Function(String execId, int cols, int rows)? execOpener,
  })  : _client = client,
        _execOpener = execOpener;

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) =>
      _client.get(baseUri.replace(path: path, queryParameters: query));

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      _client.delete(baseUri.replace(path: path, queryParameters: query));

  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    final h = <String, String>{...?headers};
    String? encoded;
    if (body != null) {
      encoded = body is String ? body : jsonEncode(body);
      h['Content-Type'] = 'application/json';
    }
    return _client.post(uri, headers: h, body: encoded);
  }

  Stream<List<int>> _openStream(http.Request request) {
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    controller.onListen = () async {
      try {
        final response = await _client.send(request);
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          controller.addError(TransportException(response.statusCode, body));
          await controller.close();
          return;
        }
        sub = response.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: () => controller.close(),
          cancelOnError: true,
        );
      } catch (e) {
        controller.addError(e);
        await controller.close();
      }
    };
    // Cancel just stops reading; the shared client stays alive for other calls.
    controller.onCancel = () async => sub?.cancel();
    return controller.stream;
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) =>
      _openStream(http.Request('GET', baseUri.replace(path: path, queryParameters: query)));

  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) {
    final request = http.Request('POST', baseUri.replace(path: path, queryParameters: query));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = body is String ? body : jsonEncode(body);
    }
    return _openStream(request);
  }

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) {
    final opener = _execOpener;
    if (opener == null) {
      throw UnsupportedError('exec requires a hijack opener (use ConnectionConfig to build a live TlsTransport)');
    }
    return opener(execId, cols, rows);
  }
}

/// Hijacks `POST /exec/{id}/start` and returns the detached socket as a duplex
/// channel. Exercised by the manual smoke test (real socket; not unit-tested).
Future<ExecChannel> hijackExec(HttpClient httpClient, Uri baseUri, String execId, int cols, int rows) async {
  final req = await httpClient.openUrl('POST', baseUri.replace(path: '/exec/$execId/start'));
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  req.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
  req.headers.set('Upgrade', 'tcp');
  req.add(utf8.encode(jsonEncode({'Detach': false, 'Tty': true})));
  final resp = await req.close();
  final socket = await resp.detachSocket();
  return SocketExecChannel(
    input: socket,
    onSend: socket.add,
    onClose: () async {
      await socket.flush();
      socket.destroy();
    },
  );
}
