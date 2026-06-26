import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/container_stats.dart';
import 'providers.dart';

const int kStatsWindow = 60;

enum StatsStatus { loading, streaming, error }

class StatsState {
  final ContainerStats? latest;
  final List<double> cpuHistory;
  final List<double> memHistory;
  final StatsStatus status;
  final String? error;

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
    String? error,
  }) =>
      StatsState(
        latest: latest ?? this.latest,
        cpuHistory: cpuHistory ?? this.cpuHistory,
        memHistory: memHistory ?? this.memHistory,
        status: status ?? this.status,
        error: error ?? this.error,
      );
}

class StatsNotifier extends StateNotifier<StatsState> {
  StreamSubscription<ContainerStats>? _sub;

  StatsNotifier(DockerApiClient client, String id) : super(const StatsState()) {
    _sub = client.streamContainerStats(id).listen(
      (s) {
        final cpu = [...state.cpuHistory, s.cpuPercent];
        final mem = [...state.memHistory, s.memoryPercent];
        state = state.copyWith(
          latest: s,
          cpuHistory: cpu.length > kStatsWindow ? cpu.sublist(cpu.length - kStatsWindow) : cpu,
          memHistory: mem.length > kStatsWindow ? mem.sublist(mem.length - kStatsWindow) : mem,
          status: StatsStatus.streaming,
        );
      },
      onError: (Object e) => state = state.copyWith(status: StatsStatus.error, error: '$e'),
      cancelOnError: true,
    );
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// Live stats for a container; auto-disposes (and cancels the stream) when the
/// screen that watches it leaves.
final statsProvider = StateNotifierProvider.autoDispose.family<StatsNotifier, StatsState, String>((ref, id) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return StatsNotifier(client, id);
});
