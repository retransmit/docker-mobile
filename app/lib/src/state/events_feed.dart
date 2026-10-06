import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/models/docker_event.dart';

const int kEventsBufferCap = 500;

class EventsState {
  final List<DockerEvent> events;
  final String? filterType;

  const EventsState({this.events = const [], this.filterType});

  List<DockerEvent> get visibleEvents =>
      filterType == null ? events : events.where((e) => e.type == filterType).toList();

  EventsState copyWith({List<DockerEvent>? events, String? filterType, bool clearFilter = false}) => EventsState(
        events: events ?? this.events,
        filterType: clearFilter ? null : (filterType ?? this.filterType),
      );
}

/// The session's event history (newest first, capped), fed by the events hub.
class EventsFeed extends StateNotifier<EventsState> {
  EventsFeed() : super(const EventsState());

  void add(DockerEvent e) {
    final next = [e, ...state.events];
    state = state.copyWith(events: next.length > kEventsBufferCap ? next.sublist(0, kEventsBufferCap) : next);
  }

  void clear() => state = state.copyWith(events: const []);

  void setFilter(String? type) =>
      state = type == null ? state.copyWith(clearFilter: true) : state.copyWith(filterType: type);
}
