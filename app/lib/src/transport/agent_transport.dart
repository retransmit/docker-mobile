import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:web_socket_channel/io.dart';

import '../api/docker_error.dart';
import 'timeouts.dart';
import 'transport.dart';

/// Talks to the docker-mobile agent over HTTP(S) with a bearer token.
class AgentTransport implements Transport {
  final Uri baseUri;
  final String token;
  final http.Client _client;
  final http.Client Function() _streamClientFactory;
  final Duration streamHeaderTimeout;

  /// Socket connect budget for the HTTP clients and the exec WebSocket.
  final Duration connectTimeout;

  AgentTransport({
    required this.baseUri,
    required this.token,
    http.Client? client,
    http.Client Function()? streamClientFactory,
    this.connectTimeout = kConnectTimeout,
    this.streamHeaderTimeout = kStreamHeaderTimeout,
  })  : _client = client ?? _ioClient(connectTimeout),
        _streamClientFactory = streamClientFactory ?? (() => _ioClient(connectTimeout));

  static http.Client _ioClient(Duration connectTimeout) =>
      IOClient(HttpClient()..connectionTimeout = connectTimeout);

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    return _client.get(uri, headers: {'Authorization': 'Bearer $token'});
  }

  Stream<List<int>> _openStream(http.Request request) {
    final client = _streamClientFactory();
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;
    var clientClosed = false;
    void closeClient() {
      if (!clientClosed) {
        clientClosed = true;
        client.close();
      }
    }

    controller.onListen = () async {
      try {
        request.headers['Authorization'] = 'Bearer $token';
        final response = await client.send(request).timeout(streamHeaderTimeout);
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          controller.addError(DockerError.fromResponse(response.statusCode, body));
          await controller.close();
          closeClient();
          return;
        }
        sub = response.stream.listen(
          controller.add,
          onError: (Object e, StackTrace st) => controller.addError(DockerError.wrap(e), st),
          onDone: () async {
            await controller.close();
            closeClient();
          },
          cancelOnError: true,
        );
      } catch (e) {
        controller.addError(DockerError.wrap(e));
        await controller.close();
        closeClient();
      }
    };
    controller.onCancel = () async {
      await sub?.cancel();
      closeClient();
    };
    return controller.stream;
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    return _openStream(http.Request('GET', uri));
  }

  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    final request = http.Request('POST', uri);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = body is String ? body : jsonEncode(body);
    }
    return _openStream(request);
  }

  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    // Bearer last so a caller-supplied header can never override the token.
    final h = <String, String>{...?headers, 'Authorization': 'Bearer $token'};
    String? encoded;
    if (body != null) {
      encoded = body is String ? body : jsonEncode(body);
      h['Content-Type'] = 'application/json';
    }
    return _client.post(uri, headers: h, body: encoded);
  }

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    return _client.delete(uri, headers: {'Authorization': 'Bearer $token'});
  }

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async {
    final wsScheme = baseUri.scheme == 'https' ? 'wss' : 'ws';
    final uri = baseUri.replace(
      scheme: wsScheme,
      path: '/exec/$execId/ws',
      queryParameters: {'w': '$cols', 'h': '$rows'},
    );
    final channel = IOWebSocketChannel.connect(
      uri,
      headers: {'Authorization': 'Bearer $token'},
      connectTimeout: connectTimeout,
    );
    await channel.ready;
    return _WebSocketExecChannel(channel);
  }

  @override
  Future<void> close() async => _client.close();
}

class _WebSocketExecChannel implements ExecChannel {
  final IOWebSocketChannel _channel;
  // Cached once: the underlying WS stream is single-subscription, so re-wrapping
  // per access would throw "already listened" on a second read.
  late final Stream<List<int>> _output =
      _channel.stream.map((e) => e is String ? utf8.encode(e) : e as List<int>);
  bool _closed = false;

  _WebSocketExecChannel(this._channel);

  @override
  Stream<List<int>> get output => _output;

  @override
  void send(List<int> data) {
    if (_closed) return;
    _channel.sink.add(data);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _channel.sink.close();
  }
}
