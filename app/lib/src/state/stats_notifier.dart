import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_stats.dart';
import '../session/reconnect_policy.dart';
import 'providers.dart';
import 'stream_supervisor.dart';

const int kStatsWindow = 60;

enum StatsStatus { loading, streaming, reconnecting, error }

class StatsState {
  final ContainerStats? latest;
  final List<double> cpuHistory;
  final List<double> memHistory;
  final StatsStatus status;
  final DockerError? error;

  const StatsState({
    this.latest,
    this.cpuHistory = const [],
    this.memHistory = const [],
    this.status = StatsStatus.loading,
    this.error,
  });

  StatsState copyWith({
    ContainerStats? latest,
    List<double>? cpuHistory,
    List<double>? memHistory,
    StatsStatus? status,
    DockerError? error,
    bool clearError = false,
  }) =>
      StatsState(
        latest: latest ?? this.latest,
        cpuHistory: cpuHistory ?? this.cpuHistory,
        memHistory: memHistory ?? this.memHistory,
        status: status ?? this.status,
        error: clearError ? null : (error ?? this.error),
      );
}

class StatsNotifier extends StateNotifier<StatsState> {
  final DockerApiClient? Function() _client;
  final String _id;
  late final StreamSupervisor<ContainerStats> _supervisor;
  bool _live = true;

  StatsNotifier(this._client, this._id, {ReconnectPolicy? policy}) : super(const StatsState()) {
    _supervisor = StreamSupervisor<ContainerStats>(
      open: _open,
      onData: _onSample,
      onStatus: _onStatus,
      policy: policy,
    );
    _supervisor.start();
  }

  Stream<ContainerStats> _open() {
    final client = _client();
    if (client == null) throw const DockerError(DockerErrorKind.unknown, 'Not connected');
    return client.streamContainerStats(_id);
  }

  void _onSample(ContainerStats s) {
    final cpu = [...state.cpuHistory, s.cpuPercent];
    final mem = [...state.memHistory, s.memoryPercent];
    state = state.copyWith(
      latest: s,
      cpuHistory: cpu.length > kStatsWindow ? cpu.sublist(cpu.length - kStatsWindow) : cpu,
      memHistory: mem.length > kStatsWindow ? mem.sublist(mem.length - kStatsWindow) : mem,
      status: StatsStatus.streaming,
      clearError: true,
    );
  }

  void _onStatus(SupervisorStatus s, DockerError? error) {
    switch (s) {
      case SupervisorStatus.retrying:
      case SupervisorStatus.paused:
        state = state.copyWith(status: StatsStatus.reconnecting);
      case SupervisorStatus.failed:
        state = state.copyWith(status: StatsStatus.error, error: error);
      case SupervisorStatus.streaming:
        state = state.copyWith(
          status: state.latest == null ? StatsStatus.loading : StatsStatus.streaming,
          clearError: true,
        );
      case SupervisorStatus.idle:
      case SupervisorStatus.done:
        break;
    }
  }

  /// The session is (not) usable: pause while reconnecting or backgrounded;
  /// the history is kept and sampling restarts on resume.
  void setLive(bool live) {
    if (live == _live) return;
    _live = live;
    if (!live) {
      _supervisor.pause();
      return;
    }
    final s = _supervisor.status;
    if (s == SupervisorStatus.done || s == SupervisorStatus.failed) {
      // Ended or gave up earlier: try again now that the session is back.
      _supervisor.retry();
    } else {
      _supervisor.resume();
    }
  }

  /// Reopens now with a fresh attempt count (the error view's Retry).
  void retry() => _supervisor.retry();

  @override
  void dispose() {
    _supervisor.dispose();
    super.dispose();
  }
}

/// Live stats for a container; auto-disposes (and cancels the stream) when the
/// screen that watches it leaves. A new connection resets the history.
final statsProvider = StateNotifierProvider.autoDispose.family<StatsNotifier, StatsState, String>((ref, id) {
  ref.watch(sessionProvider.select((s) => s.sessionId));
  final notifier = StatsNotifier(() => currentClient(ref), id, policy: ref.read(reconnectPolicyProvider));
  notifier.setLive(ref.read(sessionProvider).streamsUsable);
  ref.listen<bool>(sessionProvider.select((s) => s.streamsUsable), (_, live) => notifier.setLive(live));
  return notifier;
});
