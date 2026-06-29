import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_inspect.dart';
import '../api/models/log_line.dart';
import '../api/stdcopy.dart';
import 'providers.dart';

const int kLogBufferCap = 5000;

enum LogsStatus { streaming, paused, idle, error }

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
  final DockerApiClient _client;
  final String _id;
  final bool _tty;
  StreamSubscription<LogChunk>? _sub;
  final Map<LogStream, String> _partial = {};
  final List<LogLine> _buf = <LogLine>[];

  LogsNotifier(this._client, this._id, this._tty) : super(const LogsState()) {
    _start();
  }

  void _start() {
    _sub?.cancel();
    _partial.clear();
    _buf.clear();
    state = state.copyWith(lines: _buf, status: LogsStatus.streaming, clearError: true);
    _sub = _client
        .streamContainerLogs(
          _id,
          tty: _tty,
          follow: state.following,
          tail: state.tail,
          timestamps: state.timestamps,
        )
        .listen(_onChunk, onError: _onError, onDone: _onDone, cancelOnError: true);
  }

  void _onChunk(LogChunk chunk) {
    final text = utf8.decode(chunk.bytes, allowMalformed: true);
    final combined = (_partial[chunk.source] ?? '') + text;
    final parts = combined.split('\n');
    _partial[chunk.source] = parts.removeLast(); // trailing partial line
    if (parts.isEmpty) return;
    _buf.addAll(parts.map((p) => _toLine(chunk.source, p)));
    if (_buf.length > kLogBufferCap) {
      _buf.removeRange(0, _buf.length - kLogBufferCap);
    }
    state = state.copyWith(lines: _buf);
  }

  LogLine _toLine(LogStream source, String raw) {
    if (!state.timestamps) return LogLine(source: source, text: raw);
    final space = raw.indexOf(' ');
    if (space > 0) {
      final ts = DateTime.tryParse(raw.substring(0, space));
      if (ts != null) {
        return LogLine(source: source, text: raw.substring(space + 1), timestamp: ts);
      }
    }
    return LogLine(source: source, text: raw);
  }

  void _onError(Object e, StackTrace _) =>
      state = state.copyWith(status: LogsStatus.error, error: e.toString());

  void _onDone() {
    if (state.status != LogsStatus.error) {
      state = state.copyWith(status: LogsStatus.idle);
    }
  }

  /// Pause = stop the live tail but KEEP the buffered lines (freeze).
  /// Resume = restart streaming live.
  void setFollowing(bool value) {
    if (value == state.following) return;
    if (value) {
      state = state.copyWith(following: true);
      _start();
    } else {
      _sub?.cancel();
      _sub = null;
      state = state.copyWith(following: false, status: LogsStatus.paused);
    }
  }

  void setTimestamps(bool value) {
    state = state.copyWith(timestamps: value);
    _start();
  }

  void setTail(int? value) {
    state = state.copyWith(tail: value, clearTail: value == null);
    _start();
  }

  void setSearch(String value) => state = state.copyWith(search: value);

  void retry() => _start();

  String snapshot() => state.lines.map((l) => l.text).join('\n');

  @override
  void dispose() {
    _sub?.cancel();
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
    final client = ref.watch(dockerClientProvider);
    if (client == null) throw StateError('Not connected');
    return LogsNotifier(client, key.id, key.tty);
  },
);
