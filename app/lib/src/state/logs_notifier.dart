import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
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

  /// How many lines carried exactly [_cursor].
  int _atCursor = 0;

  /// `since` is inclusive: a resume resends the lines stamped at the cursor.
  /// Lines before [_floor], and the first [_repeats] lines at it, are repeats.
  int? _floor;
  int _repeats = 0;
  bool _live = true;

  /// Whether the stream last opened follows; a one-off fetch does not.
  bool _openFollows = true;

  /// A one-off fetch is owed: the tail changed while the session was away,
  /// or the session dropped in the middle of one.
  bool _reloadOwed = false;

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
    _repeats = _atCursor;
    _openFollows = state.following;
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
        if (floor != null) {
          if (nanos < floor) return null;
          if (nanos == floor && _repeats > 0) {
            _repeats--;
            return null;
          }
        }
        final cursor = _cursor;
        if (cursor == null || nanos > cursor) {
          _cursor = nanos;
          _atCursor = 1;
        } else if (nanos == cursor) {
          _atCursor++;
        }
        return LogLine(
          source: source,
          text: raw.substring(space + 1),
          timestamp: DateTime.fromMicrosecondsSinceEpoch(nanos ~/ 1000, isUtc: true),
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
    final s = _supervisor.status;
    if (_live && state.following) {
      _reloadOwed = false; // following starts from the tail or the cursor anyway
      if (s == SupervisorStatus.paused) {
        _supervisor.resume();
      } else if (s == SupervisorStatus.done || s == SupervisorStatus.failed || !_openFollows) {
        // Ended, gave up, or only a one-off fetch is running: follow from
        // the cursor.
        _supervisor.retry();
      }
      return;
    }
    final fetching = s == SupervisorStatus.streaming || s == SupervisorStatus.retrying;
    if (!_live && fetching && !_openFollows) _reloadOwed = true; // cut short by the session
    _supervisor.pause();
    if (_supervisor.status == SupervisorStatus.paused) {
      state = state.copyWith(status: _live ? LogsStatus.paused : LogsStatus.reconnecting);
    }
    if (_live && _reloadOwed) {
      // Make up the one-off fetch now that the session is back.
      _reloadOwed = false;
      _supervisor.retry();
    }
  }

  /// The session is (not) usable: pause while reconnecting or backgrounded.
  void setLive(bool live) {
    // A new connection disposes this notifier, and the session update that
    // does so still reaches the replaced provider's listener.
    if (!mounted || live == _live) return;
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
    _atCursor = 0;
    _floor = null;
    _repeats = 0;
    _buf.clear();
    state = state.copyWith(tail: value, clearTail: value == null, lines: _buf);
    if (_live) {
      _supervisor.retry();
    } else {
      _reloadOwed = true;
    }
  }

  void setSearch(String value) => state = state.copyWith(search: value);

  /// Reopens now, continuing from the last line received. Ignored while the
  /// session is away: the stream restarts by itself when it returns, if the
  /// user follows.
  void retry() {
    if (_live) _supervisor.retry();
  }

  String snapshot() => state.lines.map((l) => l.text).join('\n');

  @override
  void dispose() {
    _supervisor.dispose();
    super.dispose();
  }
}

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
