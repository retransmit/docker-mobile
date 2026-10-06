// Private fields are bound to public named constructor params (e.g. `open`),
// so keep the explicit initializer-list assignment.
// ignore_for_file: prefer_initializing_formals
import 'dart:async';

import '../api/docker_error.dart';
import '../api/models/docker_event.dart';
import '../api/timestamps.dart';

enum EventCategory { container, image, network, volume, other }

EventCategory categoryOf(String type) => switch (type) {
      'container' => EventCategory.container,
      'image' => EventCategory.image,
      'network' => EventCategory.network,
      'volume' => EventCategory.volume,
      _ => EventCategory.other,
    };

/// Refreshes the data affected by daemon events.
abstract class Invalidator {
  void list(EventCategory category);
  void detail(EventCategory category, String id);
  void dashboard();

  /// The connection came back on a new transport, or the app returned to the
  /// foreground: refresh everything shown.
  void all();
}

/// Owns the session's single events subscription. Forwards every event,
/// schedules debounced refreshes, tracks a resume cursor, and reports a
/// lost stream (error or clean end) exactly once per subscription.
class EventsHub {
  final Stream<DockerEvent> Function(String? since) _open;
  final void Function(DockerEvent) _onEvent;
  final Invalidator _invalidator;
  final void Function(DockerError) _onLost;
  final Duration debounce;
  final Duration dashboardDebounce;

  StreamSubscription<DockerEvent>? _sub;
  int _generation = 0;
  int? _cursorNano;
  final Map<String, Timer> _timers = {};

  EventsHub({
    required Stream<DockerEvent> Function(String? since) open,
    required void Function(DockerEvent) onEvent,
    required Invalidator invalidator,
    required void Function(DockerError) onLost,
    this.debounce = const Duration(milliseconds: 500),
    this.dashboardDebounce = const Duration(seconds: 2),
  })  : _open = open,
        _onEvent = onEvent,
        _invalidator = invalidator,
        _onLost = onLost;

  /// Raw Engine time of the newest event seen, in nanoseconds.
  int? get cursorNano => _cursorNano;

  bool get active => _sub != null;

  /// Begins a new subscription with no cursor (a new connection).
  void start() {
    _cancelSubscription();
    _cursorNano = null;
    _listen();
  }

  /// Reopens after [pause], [stop] or a lost stream, from the cursor.
  void resume() {
    _cancelSubscription();
    _listen();
  }

  /// Stops reading without reporting a loss; keeps the cursor and timers.
  void pause() => _cancelSubscription();

  /// Stops reading and drops pending refreshes; keeps the cursor.
  void stop() {
    _cancelSubscription();
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
  }

  void _cancelSubscription() {
    _generation++;
    final sub = _sub;
    _sub = null;
    sub?.cancel();
  }

  void _listen() {
    final gen = ++_generation;
    final floor = _cursorNano;
    final Stream<DockerEvent> stream;
    try {
      stream = _open(floor == null ? null : formatUnixNanos(floor));
    } catch (e) {
      _lost(gen, DockerError.wrap(e));
      return;
    }
    _sub = stream.listen(
      (e) {
        if (gen != _generation) return;
        final t = e.timeNano;
        if (floor != null && t != null && t <= floor) return; // since is inclusive
        if (t != null && (_cursorNano == null || t > _cursorNano!)) _cursorNano = t;
        _onEvent(e);
        _schedule(e);
      },
      onError: (Object e) => _lost(gen, DockerError.wrap(e)),
      onDone: () => _lost(gen, const DockerError(DockerErrorKind.network, 'The daemon closed the event stream')),
      cancelOnError: true,
    );
  }

  void _lost(int gen, DockerError error) {
    if (gen != _generation) return;
    _generation++;
    _sub = null;
    _onLost(error);
  }

  void _schedule(DockerEvent e) {
    final category = categoryOf(e.type);
    if (category == EventCategory.other) return;
    // Health checks run as exec_* events on every interval; they change
    // nothing a list shows.
    if (category == EventCategory.container && e.action.startsWith('exec_')) return;
    _debounce('list:${category.name}', debounce, () => _invalidator.list(category));
    final hasDetail = category == EventCategory.container || category == EventCategory.image;
    if (hasDetail && e.actorId.isNotEmpty) {
      _debounce('detail:${category.name}:${e.actorId}', debounce, () => _invalidator.detail(category, e.actorId));
    }
    _debounce('dashboard', dashboardDebounce, _invalidator.dashboard);
  }

  void _debounce(String key, Duration delay, void Function() fire) {
    _timers[key]?.cancel();
    _timers[key] = Timer(delay, () {
      _timers.remove(key);
      fire();
    });
  }
}
