import 'dart:async';

import 'package:http/http.dart' as http;

import 'transport.dart';

/// Talks to the docker-mobile agent over HTTP(S) with a bearer token.
class AgentTransport implements Transport {
  final Uri baseUri;
  final String token;
  final http.Client _client;
  final http.Client Function() _streamClientFactory;

  AgentTransport({
    required this.baseUri,
    required this.token,
    http.Client? client,
    http.Client Function()? streamClientFactory,
  })  : _client = client ?? http.Client(),
        _streamClientFactory = streamClientFactory ?? (() => http.Client());

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    return _client.get(uri, headers: {'Authorization': 'Bearer $token'});
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) {
    final uri = baseUri.replace(path: path, queryParameters: query);
    final client = _streamClientFactory();
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;

    // close() is invoked both by the body's onDone and by onCancel (which the
    // SDK fires when the done event is delivered downstream); guard so an
    // arbitrary http.Client is never closed twice.
    var clientClosed = false;
    void closeClient() {
      if (!clientClosed) {
        clientClosed = true;
        client.close();
      }
    }

    controller.onListen = () async {
      try {
        final request = http.Request('GET', uri)
          ..headers['Authorization'] = 'Bearer $token';
        final response = await client.send(request);
        if (response.statusCode != 200) {
          final body = await response.stream.bytesToString();
          controller.addError(TransportException(response.statusCode, body));
          await controller.close();
          closeClient();
          return;
        }
        sub = response.stream.listen(
          controller.add,
          onError: controller.addError,
          onDone: () async {
            await controller.close();
            closeClient();
          },
          cancelOnError: true,
        );
      } catch (e) {
        controller.addError(e);
        await controller.close();
        closeClient();
      }
    };
    controller.onCancel = () async {
      await sub?.cancel();
      closeClient(); // aborts the in-flight request
    };
    return controller.stream;
  }
}
