# docker-mobile Phase 2D — Daemon Events Feed — Design Spec

**Date:** 2026-06-26
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** All of Milestone 1 + Phase 2A/2B/2C (on `main`). Second half of the "live events + stats" work (item #2); completes it.

---

## 1. Summary

Phase 2D adds a **live daemon events feed** — a newest-first list of Docker events (`GET /events`) with type-filter chips — reached via an **Events** action on the System dashboard. It mirrors the stats slice structurally (model + stream + `StateNotifier` ring buffer + screen).

## 2. Goals / Non-goals

**Goals**
- `DockerEvent` — a pure model parsing one event (type, action, target, time).
- `DockerApiClient.streamEvents() → Stream<DockerEvent>` (NDJSON byte-buffered).
- `EventsNotifier` — a ring buffer (newest first) + a type filter.
- `EventsScreen` — filter-chip row (All/Containers/Images/Networks/Volumes) + the feed.
- An **Events** action on `SystemScreen` → pushed `EventsScreen`.

**Non-goals (this slice)**
- Server-side `/events` filtering (`since`/`until`/`filters` query) — filter client-side.
- Tapping an event to jump to the related container/image; persistence; search; pause/resume.
- Notifications/background event watching (a later agent-only feature).

## 3. Scope decisions (locked)

- **Entry point:** an Events app-bar `IconButton` (`Icons.bolt`) on `SystemScreen` → pushed `EventsScreen` (keeps the nav bar at 5 tabs).
- **Filtering:** client-side type-filter chips — **All · Containers · Images · Networks · Volumes** (map to event `type` `container`/`image`/`network`/`volume`; All = no filter).
- **Buffer:** `kEventsBufferCap = 500`, newest first (prepend; trim the tail).
- **Stream:** `GET /events` NDJSON, byte-buffered (same pattern as `streamContainerStats`/`pullImage`); malformed lines skipped; stream canceled on screen leave via an `autoDispose` provider.
- **Target label:** `Actor.Attributes.name` if present, else the short (`≤12`) `Actor.ID`.
- **Time:** prefer `timeNano` (µs precision), else `time` (seconds); shown as local `HH:mm:ss`.

## 4. Architecture

```
SystemScreen app bar: [refresh] [bolt=Events] [logout]
  bolt -> Navigator.push(EventsScreen)

EventsScreen (ConsumerWidget)
  FilterChip row (All/Containers/Images/Networks/Volumes) -> notifier.setFilter(type|null)
  ListView(state.visibleEvents): icon(type) · 'type · action' · target · HH:mm:ss

EventsNotifier (StateNotifier<EventsState>)        [lib/src/state/events_notifier.dart]
  client.streamEvents().listen -> prepend (cap kEventsBufferCap) ; status ; filterType
  EventsState.visibleEvents = filterType == null ? events : events.where(type == filterType)
  eventsProvider = StateNotifierProvider.autoDispose<EventsNotifier, EventsState>

DockerApiClient.streamEvents() -> transport.stream('/events') -> DockerEvent.fromJson per NDJSON line

DockerEvent.fromJson (pure)                        [lib/src/api/models/docker_event.dart]
  type, action, target, time
```

## 5. Components

### 5.1 Model — `lib/src/api/models/docker_event.dart`
- `class DockerEvent { final String type; final String action; final String target; final DateTime? time; const DockerEvent({...}); factory DockerEvent.fromJson(Map<String,dynamic>); }`
- `type` = `Type` ?? ''; `action` = `Action` ?? '' (strip any `:` exec sub-action detail is out of scope — keep raw).
- `target`: `actor.Attributes['name']` (non-empty) else short `actor.ID` (≤12 chars), where `actor = json['Actor'] ?? {}`.
- `time`: `timeNano` → `DateTime.fromMicrosecondsSinceEpoch(timeNano ~/ 1000)`; else `time` (sec) → `fromMillisecondsSinceEpoch(time*1000)`; else null.
- Tolerates missing `Actor`/`Attributes`/`Type`/`Action`.

### 5.2 DockerApiClient — addition
- `Stream<DockerEvent> streamEvents()` — `transport.stream('/events')`; byte-buffer to newline boundaries; `jsonDecode` each line → `DockerEvent.fromJson`; skip parse failures. (Same NDJSON pattern as `streamContainerStats`.)

### 5.3 State — `lib/src/state/events_notifier.dart`
- `const int kEventsBufferCap = 500;`
- `enum EventsStatus { streaming, error }`
- `class EventsState { final List<DockerEvent> events; final String? filterType; final EventsStatus status; final String? error; List<DockerEvent> get visibleEvents; copyWith({..., bool clearFilter}); }` — `visibleEvents = filterType == null ? events : events.where((e) => e.type == filterType).toList()`.
- `class EventsNotifier extends StateNotifier<EventsState>`: constructor `EventsNotifier(DockerApiClient client)` subscribes; on each event → `events = [e, ...events]` trimmed to `kEventsBufferCap`, `status = streaming`; on error → `error`/`status = error`; `void setFilter(String? type)` → `copyWith(filterType: type)` or `copyWith(clearFilter: true)` for null; `dispose()` cancels.
- `final eventsProvider = StateNotifierProvider.autoDispose<EventsNotifier, EventsState>((ref) { final c = ref.watch(dockerClientProvider); if (c == null) throw StateError('Not connected'); return EventsNotifier(c); });`

### 5.4 UI
- `EventsScreen` (`ConsumerWidget`): app bar "Events"; body = a `Wrap` of `FilterChip`s (All/Containers/Images/Networks/Volumes; selected reflects `filterType`, tap → `read(eventsProvider.notifier).setFilter(...)`) above a `ListView` of `state.visibleEvents` (`ListTile`: leading icon by type [container→`Icons.inventory`, image→`Icons.layers`, network→`Icons.hub`, volume→`Icons.storage`, else `Icons.bolt`], title `'$type · $action'`, subtitle `target`, trailing local `HH:mm:ss`). Error → error text; empty → "No events yet.".
- `SystemScreen`: add an Events `IconButton(Icons.bolt, tooltip: 'Events')` to the app-bar actions → push `EventsScreen`.

## 6. Data flow & error handling
- Stream: `transport.stream('/events')` → NDJSON → `DockerEvent` → notifier (prepend, cap) → filtered list → UI. Cancel on dispose closes the channel.
- A transport error → error status; malformed lines skipped (no crash). No secrets.

## 7. File structure
```
app/lib/src/api/models/docker_event.dart          # DockerEvent + fromJson
app/lib/src/api/docker_api_client.dart            # + streamEvents
app/lib/src/state/events_notifier.dart            # EventsState + EventsNotifier + eventsProvider + kEventsBufferCap
app/lib/src/ui/events_screen.dart                 # EventsScreen (filter chips + feed)
app/lib/src/ui/system_screen.dart                 # + Events app-bar action
app/test/...                                        # mirrors the above
```

## 8. Testing
- `DockerEvent.fromJson`: parses `Type`/`Action`; `target` = `Actor.Attributes.name` when present, else short `Actor.ID`; `time` from `timeNano`; missing `Actor`/`Attributes` → empty target, no throw.
- `streamEvents`: two events split across byte chunks → two `DockerEvent`; a malformed line skipped.
- `EventsNotifier`: prepend keeps newest-first and caps at `kEventsBufferCap` (feed `cap+5`, assert length `cap` and `events.first` is the newest); `setFilter('container')` → `visibleEvents` only container events; `setFilter(null)` → all; stream error → `EventsStatus.error`.
- `EventsScreen` (fake stream of mixed-type events): renders the events; tapping the **Containers** chip narrows to container events; the System **Events** action opens `EventsScreen`.

## 9. Dependencies
None new (reuses the streaming foundation).

## 10. Open questions / to confirm during planning
- `Action` values can carry detail (e.g. `exec_create: <cmd>`); keep the raw string this slice (no splitting).
- cgroup/daemon `Type` set is open-ended; the chips cover the four common object types and `All`; other-typed events still appear under All.
- `time` vs `timeNano` presence: both are usually sent; prefer `timeNano`. If neither, the row omits the time.
