import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';
import 'package:docker_mobile/src/api/docker_api_client.dart';

class _FakeTransport implements Transport {
  http.Response getResponse = http.Response('{}', 200);
  http.Response postResponse = http.Response('{}', 201);
  String? postPath;
  Object? postBody;
  Map<String, String>? postQuery;

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) async => getResponse;

  @override
  Future<http.Response> post(String path,
      {Map<String, String>? query, Object? body, Map<String, String>? headers}) async {
    postPath = path;
    postBody = body;
    postQuery = query;
    return postResponse;
  }

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => const Stream.empty();

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) =>
      throw UnimplementedError();

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      throw UnimplementedError();
}

void main() {
  test('createExec posts the exec config and returns the Id', () async {
    final t = _FakeTransport()..postResponse = http.Response('{"Id":"e123"}', 201);
    final id = await DockerApiClient(t).createExec('c1', cmd: ['/bin/sh']);

    expect(id, 'e123');
    expect(t.postPath, '/containers/c1/exec');
    final body = t.postBody as Map<String, dynamic>;
    expect(body['Tty'], true);
    expect(body['AttachStdin'], true);
    expect(body['Cmd'], ['/bin/sh']);
  });

  test('resizeExec posts h and w as query params', () async {
    final t = _FakeTransport()..postResponse = http.Response('', 200);
    await DockerApiClient(t).resizeExec('e1', cols: 120, rows: 40);
    expect(t.postPath, '/exec/e1/resize');
    expect(t.postQuery, {'h': '40', 'w': '120'});
  });

  test('inspectExec parses running + exit code', () async {
    final t = _FakeTransport()..getResponse = http.Response('{"Running":false,"ExitCode":0}', 200);
    final e = await DockerApiClient(t).inspectExec('e1');
    expect(e.running, isFalse);
    expect(e.exitCode, 0);
  });

  test('createExec throws on non-201', () async {
    final t = _FakeTransport()..postResponse = http.Response('boom', 500);
    expect(() => DockerApiClient(t).createExec('c1', cmd: ['sh']),
        throwsA(isA<DockerApiException>()));
  });
}
