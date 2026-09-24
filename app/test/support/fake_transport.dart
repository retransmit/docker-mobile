import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:docker_mobile/src/transport/transport.dart';

/// One call made against a [FakeTransport]. `method` is one of
/// GET, POST, DELETE, STREAM, POSTSTREAM, EXEC.
class RecordedCall {
  final String method;
  final String path;
  final Map<String, String>? query;
  final Object? body;
  final Map<String, String>? headers;
  const RecordedCall(this.method, this.path, {this.query, this.body, this.headers});

  @override
  String toString() => '$method $path${query == null ? '' : ' $query'}';
}

class _Rule {
  final String method;
  final Pattern path; // String = exact match, RegExp = hasMatch
  final http.Response Function(RecordedCall call)? respond;
  final Stream<List<int>> Function(RecordedCall call)? stream;
  final Object? error;
  final bool hang;
  const _Rule(this.method, this.path, {this.respond, this.stream, this.error, this.hang = false});

  bool matches(String m, String p) {
    if (m != method) return false;
    final pat = path;
    return pat is RegExp ? pat.hasMatch(p) : pat == p;
  }
}

/// An exec channel the test drives: push daemon output through [controller],
/// read what the app sent from [sent].
class FakeExecChannel implements ExecChannel {
  final controller = StreamController<List<int>>();
  final sent = <List<int>>[];
  bool closed = false;

  @override
  Stream<List<int>> get output => controller.stream;

  @override
  void send(List<int> data) => sent.add(data);

  @override
  Future<void> close() async {
    closed = true;
    if (!controller.isClosed) await controller.close();
  }
}

/// A programmable [Transport]. Register rules (last registered wins); anything
/// unmatched answers 404 (buffered calls) or an empty stream. Every call is
/// appended to [calls].
class FakeTransport implements Transport {
  final List<_Rule> _rules = [];
  final List<RecordedCall> calls = [];
  final List<FakeExecChannel> execChannels = [];
  bool closed = false;

  /// When set, [execAttach] throws this instead of opening a channel.
  Object? execError;

  FakeTransport();

  /// Every buffered call (GET/POST/DELETE) returns [response].
  factory FakeTransport.always(http.Response response) => FakeTransport()
    ..onGet(RegExp('.*'), (_) => response)
    ..onPost(RegExp('.*'), (_) => response)
    ..onDelete(RegExp('.*'), (_) => response);

  /// Every GET stream yields [stream]; buffered GETs answer `{}` 200 so an
  /// inspect-before-stream call succeeds.
  /// The same Stream instance is handed to every stream() call, so pass a broadcast or multi-subscription stream if the code under test subscribes more than once.
  factory FakeTransport.streaming(Stream<List<int>> stream) => FakeTransport()
    ..onGet(RegExp('.*'), (_) => http.Response('{}', 200))
    ..onStream(RegExp('.*'), (_) => stream);

  void onGet(Pattern path, http.Response Function(RecordedCall) respond) =>
      _rules.add(_Rule('GET', path, respond: respond));
  void onPost(Pattern path, http.Response Function(RecordedCall) respond) =>
      _rules.add(_Rule('POST', path, respond: respond));
  void onDelete(Pattern path, http.Response Function(RecordedCall) respond) =>
      _rules.add(_Rule('DELETE', path, respond: respond));
  void onStream(Pattern path, Stream<List<int>> Function(RecordedCall) stream) =>
      _rules.add(_Rule('STREAM', path, stream: stream));
  void onPostStream(Pattern path, Stream<List<int>> Function(RecordedCall) stream) =>
      _rules.add(_Rule('POSTSTREAM', path, stream: stream));

  /// The matching call throws [error] (buffered) or emits it (streams).
  void throwOn(String method, Pattern path, Object error) => _rules.add(_Rule(method, path, error: error));

  /// The matching buffered call never completes; a matching stream never emits (for timeout tests).
  void hangOn(String method, Pattern path) => _rules.add(_Rule(method, path, hang: true));

  RecordedCall? get lastCall => calls.isEmpty ? null : calls.last;
  String? get lastPath => lastCall?.path;
  Map<String, String>? get lastQuery => lastCall?.query;
  List<RecordedCall> get posts => calls.where((c) => c.method == 'POST').toList();
  FakeExecChannel get lastChannel => execChannels.last;

  _Rule? _find(String method, String path) {
    for (final r in _rules.reversed) {
      if (r.matches(method, path)) return r;
    }
    return null;
  }

  Future<http.Response> _buffered(
      String method, String path, Map<String, String>? query, Object? body, Map<String, String>? headers) {
    final call = RecordedCall(method, path, query: query, body: body, headers: headers);
    calls.add(call);
    final rule = _find(method, path);
    if (rule == null) {
      return Future.value(http.Response('{"message":"fake: no rule for $method $path"}', 404));
    }
    if (rule.hang) return Completer<http.Response>().future;
    if (rule.error != null) return Future.error(rule.error!);
    return Future.value(rule.respond!(call));
  }

  Stream<List<int>> _streamed(String method, String path, Map<String, String>? query, Object? body) {
    final call = RecordedCall(method, path, query: query, body: body);
    calls.add(call);
    final rule = _find(method, path);
    if (rule == null) return const Stream.empty();
    if (rule.hang) return StreamController<List<int>>().stream;
    if (rule.error != null) return Stream.error(rule.error!);
    return rule.stream!(call);
  }

  @override
  Future<http.Response> get(String path, {Map<String, String>? query}) =>
      _buffered('GET', path, query, null, null);

  @override
  Future<http.Response> post(String path,
          {Map<String, String>? query, Object? body, Map<String, String>? headers}) =>
      _buffered('POST', path, query, body, headers);

  @override
  Future<http.Response> delete(String path, {Map<String, String>? query}) =>
      _buffered('DELETE', path, query, null, null);

  @override
  Stream<List<int>> stream(String path, {Map<String, String>? query}) => _streamed('STREAM', path, query, null);

  @override
  Stream<List<int>> postStream(String path, {Map<String, String>? query, Object? body}) =>
      _streamed('POSTSTREAM', path, query, body);

  @override
  Future<ExecChannel> execAttach(String execId, {required int cols, required int rows}) async {
    calls.add(RecordedCall('EXEC', '/exec/$execId/start', query: {'cols': '$cols', 'rows': '$rows'}));
    if (execError != null) throw execError!;
    final ch = FakeExecChannel();
    execChannels.add(ch);
    return ch;
  }

  @override
  Future<void> close() async => closed = true;
}

/// `jsonResponse({'Id': 'x'}, 201)` instead of hand-encoding JSON strings.
http.Response jsonResponse(Object body, [int status = 200]) => http.Response(jsonEncode(body), status);
