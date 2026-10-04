// Private fields are bound to public named constructor params (e.g. `open`),
// so keep the explicit initializer-list assignment.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import '../api/docker_error.dart';
import '../session/reconnect_policy.dart';

enum SupervisorStatus { idle, streaming, paused, retrying, failed, done }

/// Keeps one long-lived stream alive: reopens it with backoff after retryable
/// errors, pauses and resumes it on request, and reports every transition.
/// [open] is called afresh on every (re)connect, so it can pick up a new
/// transport or a resume cursor.
class StreamSupervisor<T> {
  final Stream<T> Function() _open;
  final void Function(T) _onData;
  final void Function(SupervisorStatus status, DockerError? error) _onStatus;
  final ReconnectPolicy _policy;
  final bool retryOnDone;

  StreamSubscription<T>? _sub;
  Timer? _timer;
  int _attempt = 0;
  int _generation = 0;
  bool _resumable = false;
  bool _disposed = false;
  SupervisorStatus _status = SupervisorStatus.idle;

  StreamSupervisor({
    required Stream<T> Function() open,
    required void Function(T) onData,
    required void Function(SupervisorStatus status, DockerError? error) onStatus,
    ReconnectPolicy? policy,
    this.retryOnDone = false,
  })  : _open = open,
        _onData = onData,
        _onStatus = onStatus,
        _policy = policy ?? ReconnectPolicy();

  SupervisorStatus get status => _status;

  /// Opens the stream for the first time.
  void start() {
    _attempt = 0;
    _connect();
  }

  /// Stops reading (stream cancelled, retry timer cancelled) while streaming
  /// or retrying. Anything else is left alone.
  void pause() {
    if (_disposed) return;
    if (_status != SupervisorStatus.streaming && _status != SupervisorStatus.retrying) return;
    _cancel();
    _resumable = true;
    _set(SupervisorStatus.paused);
  }

  /// Reopens a stream that [pause] stopped.
  void resume() {
    if (_disposed || _status != SupervisorStatus.paused || !_resumable) return;
    _resumable = false;
    _attempt = 0;
    _connect();
  }

  /// Reopens now with a fresh attempt count, whatever the current status.
  void retry() {
    if (_disposed) return;
    _resumable = false;
    _attempt = 0;
    _connect();
  }

  void dispose() {
    _disposed = true;
    _cancel();
  }

  void _set(SupervisorStatus s, [DockerError? error]) {
    _status = s;
    if (!_disposed) _onStatus(s, error);
  }

  void _cancel() {
    _generation++;
    _timer?.cancel();
    _timer = null;
    final sub = _sub;
    _sub = null;
    sub?.cancel();
  }

  void _connect() {
    _cancel();
    if (_disposed) return;
    final gen = _generation;
    final Stream<T> stream;
    try {
      stream = _open();
    } catch (e) {
      _handleError(e);
      return;
    }
    _set(SupervisorStatus.streaming);
    _sub = stream.listen(
      (data) {
        if (gen != _generation) return;
        _attempt = 0;
        _onData(data);
      },
      onError: (Object e) {
        if (gen != _generation) return;
        _sub = null;
        _handleError(e);
      },
      onDone: () {
        if (gen != _generation) return;
        _sub = null;
        if (retryOnDone) {
          _handleError(const DockerError(DockerErrorKind.network, 'The stream closed'));
        } else {
          _set(SupervisorStatus.done);
        }
      },
      cancelOnError: true,
    );
  }

  void _handleError(Object e) {
    if (_disposed) return;
    final error = DockerError.wrap(e);
    _attempt++;
    if (!error.retryable || _attempt > _policy.maxAttempts) {
      _set(SupervisorStatus.failed, error);
      return;
    }
    _set(SupervisorStatus.retrying, error);
    final gen = _generation;
    _timer = Timer(_policy.delay(_attempt), () {
      if (gen != _generation) return;
      _timer = null;
      _connect();
    });
  }
}
