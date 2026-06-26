import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/docker_api_client.dart';
import '../api/models/docker_event.dart';
import 'providers.dart';

const int kEventsBufferCap = 500;

enum EventsStatus { streaming, error }

class EventsState {
  final List<DockerEvent> events;
  final String? filterType;
  final EventsStatus status;
  final String? error;

  const EventsState({
    this.events = const [],
    this.filterType,
    this.status = EventsStatus.streaming,
    this.error,
  });

  List<DockerEvent> get visibleEvents =>
      filterType == null ? events : events.where((e) => e.type == filterType).toList();

  EventsState copyWith({
    List<DockerEvent>? events,
    String? filterType,
    bool clearFilter = false,
    EventsStatus? status,
    String? error,
  }) =>
      EventsState(
        events: events ?? this.events,
        filterType: clearFilter ? null : (filterType ?? this.filterType),
        status: status ?? this.status,
        error: error ?? this.error,
      );
}

class EventsNotifier extends StateNotifier<EventsState> {
  StreamSubscription<DockerEvent>? _sub;

  EventsNotifier(DockerApiClient client) : super(const EventsState()) {
    _sub = client.streamEvents().listen(
      (e) {
        final next = [e, ...state.events];
        state = state.copyWith(
          events: next.length > kEventsBufferCap ? next.sublist(0, kEventsBufferCap) : next,
          status: EventsStatus.streaming,
        );
      },
      onError: (Object e) => state = state.copyWith(status: EventsStatus.error, error: '$e'),
      cancelOnError: true,
    );
  }

  void setFilter(String? type) =>
      state = type == null ? state.copyWith(clearFilter: true) : state.copyWith(filterType: type);

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}

/// Live daemon events; auto-disposes (and cancels the stream) when the screen
/// that watches it leaves.
final eventsProvider = StateNotifierProvider.autoDispose<EventsNotifier, EventsState>((ref) {
  final client = ref.watch(dockerClientProvider);
  if (client == null) throw StateError('Not connected');
  return EventsNotifier(client);
});
