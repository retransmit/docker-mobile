// Private fields are bound to public named constructor params (e.g. `client`),
// so an initializing formal (`this._client`) would be a private named param -
// which Dart forbids. Keep the explicit initializer-list assignment.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../api/docker_error.dart';
import 'duplex_exec_channel.dart';
import 'timeouts.dart';
import 'transport.dart';

export 'duplex_exec_channel.dart' show SocketExecChannel;

/// Direct mutual-TLS transport to a Docker daemon (no agent, no bearer token).
class TlsTransport implements Transport {
  final Uri baseUri;
  final http.Client _client;
  final Future<ExecChannel> Function(String execId, int cols, int rows)? _execOpener;

  /// Budget for the response headers of a GET stream; stream bodies never time out.
  final Duration streamHeaderTimeout;

  /// Budget for the response headers of a POST stream. dockerd sends the
  /// headers of `POST /images/create` only with the first progress line,
  /// after the registry handshake, so a pull gets the long budget.
  final Duration postStreamHeaderTimeout;

  TlsTransport({
    required this.baseUri,
    required http.Client client,
    Future<ExecChannel> Function(String execId, int cols, int rows)? execOpener,
    this.streamHeaderTimeout = kStreamHeaderTimeout,
    this.postStreamHeaderTimeout = kLongRequestTimeout,
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

  Stream<List<int>> _openStream(http.Request request, Duration headerBudget) {
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    controller.onListen = () async {
      try {
        final response = await _client.send(request).timeout(headerBudget);
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          controller.addError(DockerError.fromResponse(response.statusCode, body));
          await controller.close();
          return;
        }
        sub = response.stream.listen(
          controller.add,
          onError: (Object e, StackTrace st) => controller.addError(DockerError.wrap(e), st),
          onDone: () => controller.close(),
          cancelOnError: true,
        );
      } catch (e, st) {
        controller.addError(DockerError.wrap(e), st);
        await controller.close();
      }
    };
    // Cancel just stops reading; the shared client stays alive for other calls.
    controller.onCancel = () async => sub?.cancel();
    return controller.stream;
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) =>
      _openStream(http.Request('GET', baseUri.replace(path: path, queryParameters: query)), streamHeaderTimeout);

  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) {
    final request = http.Request('POST', baseUri.replace(path: path, queryParameters: query));
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = body is String ? body : jsonEncode(body);
    }
    return _openStream(request, postStreamHeaderTimeout);
  }

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) {
    final opener = _execOpener;
    if (opener == null) {
      throw UnsupportedError('exec requires a hijack opener (use ConnectionConfig to build a live TlsTransport)');
    }
    return opener(execId, cols, rows);
  }

  @override
  Future<void> close() async => _client.close();
}

/// Hijacks `POST /exec/{id}/start` and returns the detached socket as a duplex
/// channel. Exercised by the manual smoke test (real socket; not unit-tested).
/// The upgrade response must arrive within [headerTimeout]; the hijacked stream itself never times out.
Future<ExecChannel> hijackExec(HttpClient httpClient, Uri baseUri, String execId, int cols, int rows,
    {Duration headerTimeout = kStreamHeaderTimeout}) async {
  final req = await httpClient.openUrl('POST', baseUri.replace(path: '/exec/$execId/start'));
  req.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
  req.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
  req.headers.set('Upgrade', 'tcp');
  req.add(utf8.encode(jsonEncode({'Detach': false, 'Tty': true})));
  final resp = await req.close().timeout(headerTimeout);
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
