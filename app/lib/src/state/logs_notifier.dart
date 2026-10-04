import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_inspect.dart';
import '../api/models/log_line.dart';
import '../api/stdcopy.dart';
import '../api/timestamps.dart';
import '../session/reconnect_policy.dart';
import 'providers.dart';
import 'stream_supervisor.dart';

const int kLogBufferCap = 5000;

enum LogsStatus { streaming, paused, idle, reconnecting, error }

class LogsState {
  final List<LogLine> lines;
  final bool following;
  final bool timestamps;
  final int? tail;
  final String search;
  final LogsStatus status;
  final String? error;

  const LogsState({
    this.lines = const [],
    this.following = true,
    this.timestamps = false,
    this.tail,
    this.search = '',
    this.status = LogsStatus.streaming,
    this.error,
  });

  List<LogLine> get visibleLines {
    if (search.isEmpty) return lines;
    final q = search.toLowerCase();
    return lines.where((l) => l.text.toLowerCase().contains(q)).toList();
  }

  LogsState copyWith({
    List<LogLine>? lines,
    bool? following,
    bool? timestamps,
    int? tail,
    bool clearTail = false,
    String? search,
    LogsStatus? status,
    String? error,
    bool clearError = false,
  }) {
    return LogsState(
      lines: lines ?? this.lines,
      following: following ?? this.following,
      timestamps: timestamps ?? this.timestamps,
      tail: clearTail ? null : (tail ?? this.tail),
      search: search ?? this.search,
      status: status ?? this.status,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class LogsNotifier extends StateNotifier<LogsState> {
  final DockerApiClient? Function() _client;
  final String _id;
  final bool _tty;
  late final StreamSupervisor<LogChunk> _supervisor;
  final Map<LogStream, String> _partial = {};
  final List<LogLine> _buf = <LogLine>[];

  /// Epoch nanoseconds of the newest line received; the resume point.
  int? _cursor;

  /// Lines at or before this are repeats from an inclusive `since`.
  int? _floor;
  bool _live = true;

  LogsNotifier(this._client, this._id, this._tty, {ReconnectPolicy? policy}) : super(const LogsState()) {
    _supervisor = StreamSupervisor<LogChunk>(
      open: _open,
      onData: _onChunk,
      onStatus: _onStatus,
      policy: policy,
    );
    _supervisor.start();
  }

  Stream<LogChunk> _open() {
    final client = _client();
    if (client == null) throw const DockerError(DockerErrorKind.unknown, 'Not connected');
    _partial.clear();
    final cursor = _cursor;
    _floor = cursor;
    return client.streamContainerLogs(
      _id,
      tty: _tty,
      follow: state.following,
      tail: cursor == null ? state.tail : null,
      timestamps: true,
      since: cursor == null ? null : formatUnixNanos(cursor),
    );
  }

  void _onChunk(LogChunk chunk) {
    final text = utf8.decode(chunk.bytes, allowMalformed: true);
    final combined = (_partial[chunk.source] ?? '') + text;
    final parts = combined.split('\n');
    _partial[chunk.source] = parts.removeLast(); // trailing partial line
    var added = false;
    for (final p in parts) {
      final line = _toLine(chunk.source, p);
      if (line != null) {
        _buf.add(line);
        added = true;
      }
    }
    if (!added) return;
    if (_buf.length > kLogBufferCap) {
      _buf.removeRange(0, _buf.length - kLogBufferCap);
    }
    state = state.copyWith(lines: _buf);
  }

  /// Splits the daemon's leading RFC3339Nano timestamp off [raw]. Returns
  /// null for a repeat of a line already shown before a resume.
  LogLine? _toLine(LogStream source, String raw) {
    final space = raw.indexOf(' ');
    if (space > 0) {
      final rawTs = raw.substring(0, space);
      final nanos = rfc3339ToEpochNanos(rawTs);
      if (nanos != null) {
        final floor = _floor;
        if (floor != null && nanos <= floor) return null;
        final cursor = _cursor;
        if (cursor == null || nanos > cursor) _cursor = nanos;
        return LogLine(
          source: source,
          text: raw.substring(space + 1),
          timestamp: DateTime.tryParse(rawTs),
          rawTimestamp: rawTs,
        );
      }
    }
    return LogLine(source: source, text: raw);
  }

  void _onStatus(SupervisorStatus s, DockerError? error) {
    switch (s) {
      case SupervisorStatus.streaming:
        state = state.copyWith(status: LogsStatus.streaming, clearError: true);
      case SupervisorStatus.retrying:
        state = state.copyWith(status: LogsStatus.reconnecting);
      case SupervisorStatus.paused:
        state = state.copyWith(status: _live ? LogsStatus.paused : LogsStatus.reconnecting);
      case SupervisorStatus.failed:
        state = state.copyWith(status: LogsStatus.error, error: error?.message ?? 'Log stream failed');
      case SupervisorStatus.done:
        state = state.copyWith(status: LogsStatus.idle);
      case SupervisorStatus.idle:
        break;
    }
  }

  /// Runs the stream only while the session is live and the user follows.
  void _sync() {
    if (_live && state.following) {
      final s = _supervisor.status;
      if (s == SupervisorStatus.done || s == SupervisorStatus.failed) {
        // Ended or gave up earlier: look again from the cursor.
        _supervisor.retry();
      } else {
        _supervisor.resume();
      }
    } else {
      _supervisor.pause();
      if (_supervisor.status == SupervisorStatus.paused) {
        state = state.copyWith(status: _live ? LogsStatus.paused : LogsStatus.reconnecting);
      }
    }
  }

  /// The session is (not) usable: pause while reconnecting or backgrounded.
  void setLive(bool live) {
    if (live == _live) return;
    _live = live;
    _sync();
  }

  /// Pause = freeze the view and stop reading; resume continues from the
  /// last line received (no gap, no duplicates).
  void setFollowing(bool value) {
    if (value == state.following) return;
    state = state.copyWith(following: value);
    _sync();
  }

  /// Display-only: the daemon always sends timestamps.
  void setTimestamps(bool value) => state = state.copyWith(timestamps: value);

  /// Starts over with a new tail size (a one-off fetch while paused).
  void setTail(int? value) {
    _cursor = null;
    _floor = null;
    _buf.clear();
    state = state.copyWith(tail: value, clearTail: value == null, lines: _buf);
    if (_live) _supervisor.retry();
  }

  void setSearch(String value) => state = state.copyWith(search: value);

  /// Reopens now, continuing from the last line received.
  void retry() => _supervisor.retry();

  String snapshot() => state.lines.map((l) => l.text).join('\n');

  @override
  void dispose() {
    _supervisor.dispose();
    super.dispose();
  }
}

final containerInspectProvider =
    FutureProvider.family<ContainerInspect, String>((ref, id) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return client.inspectContainer(id);
});

final logsProvider =
    StateNotifierProvider.autoDispose.family<LogsNotifier, LogsState, ({String id, bool tty})>(
  (ref, key) {
    // A new connection resets the buffer; a reconnect within it does not.
    ref.watch(sessionProvider.select((s) => s.sessionId));
    final notifier = LogsNotifier(
      () => currentClient(ref),
      key.id,
      key.tty,
      policy: ref.read(reconnectPolicyProvider),
    );
    notifier.setLive(ref.read(sessionProvider).streamsUsable);
    ref.listen<bool>(sessionProvider.select((s) => s.streamsUsable), (_, live) => notifier.setLive(live));
    return notifier;
  },
);
