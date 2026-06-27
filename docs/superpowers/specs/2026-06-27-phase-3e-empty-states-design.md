# docker-mobile Phase 3E — Designed Empty States — Design Spec

**Date:** 2026-06-27
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 3A–3D (on `main`). Fourth per-screen redesign slice.

---

## 1. Summary

Phase 3E adds a reusable `EmptyState` widget (centered tinted icon + title + optional message + optional action) and wires it into the empty branches of the list screens (Containers, Images, Networks, Volumes), the Events feed, and the Connections list — replacing today's blank screens / plain centered text. Presentational only.

## 2. Goals / Non-goals

**Goals**
- A reusable `EmptyState` widget in `widgets/resource_widgets.dart`.
- Empty-state coverage on: Containers, Images, Networks, Volumes (currently blank when empty), Events ("No events yet" → designed), Connections ("No saved connections" → designed, with an **Add connection** action).

**Non-goals (out of scope)**
- Error-state or loading-state redesign (only the empty/`data`-with-empty-list path).
- Any data/provider/model change; new screens; the stats/chart polish (next slice).
- New dependencies.

## 3. Scope decisions (locked)

- **Presentational only.** Add `EmptyState`; in each screen's `data:` branch, render `EmptyState(...)` when the (possibly filtered) list is empty, else the existing list. Loading/error branches unchanged.
- `EmptyState({required IconData icon, required String title, String? message, Widget? action})` — a centered `Column`: a large tinted icon in a circle, `title` (titleMedium), `message` (bodySmall, muted, optional), and `action` (optional widget, e.g. a button).
- **Wiring:**
  - **Containers** — `Icons.inventory_2`, "No containers", "This daemon has no containers yet." (no action; the + FAB remains).
  - **Images** — `Icons.layers`, "No images", "Pull an image to get started." (no action; the Pull app-bar icon remains).
  - **Networks** — `Icons.hub`, "No networks" (no message/action).
  - **Volumes** — `Icons.storage`, "No volumes" (no message/action).
  - **Events** — `Icons.bolt`, "No events yet", "Events appear here as activity happens on the daemon." (replaces the plain text; shown when the filtered event list is empty).
  - **Connections** — `Icons.dns`, "No connections", "Add a Docker host to get started.", **action** = a `FilledButton.icon` (add icon, "Add connection") that pushes `ConnectionScreen` (same as the + FAB).
- The screens' FABs / app-bar actions / refresh / providers are unchanged.

## 4. Architecture

```
widgets/resource_widgets.dart
  EmptyState({icon, title, message?, action?})   // centered icon + title + message + action

ContainersScreen / ImagesScreen / NetworksScreen / VolumesScreen
  data: (list) => list.isEmpty ? EmptyState(...) : ListView.builder(...)
EventsScreen
  (filtered events).isEmpty ? EmptyState(...) : ListView(...)
ProfilesScreen
  data: (list) => list.isEmpty ? EmptyState(... action: Add connection ...) : ListView(...)
```

## 5. Components

### 5.1 `EmptyState` — `widgets/resource_widgets.dart`
`class EmptyState extends StatelessWidget { final IconData icon; final String title; final String? message; final Widget? action; const EmptyState({required this.icon, required this.title, this.message, this.action}); }` — a `Center` → `Column(mainAxisSize.min)`: a ~72px circle (`secondaryContainer`) holding the icon (`onSecondaryContainer`, size ~36); the title (`titleMedium`, weight 600); the message (`bodySmall`, `onSurfaceVariant`, centered) if non-null; the action (with top padding) if non-null. Horizontal padding so messages wrap nicely.

### 5.2 Screen wiring
- Each list screen's `data:` branch gains a `list.isEmpty ? const EmptyState(...) : <existing list>`.
- Events: the existing "No events yet" `Center(Text(...))` becomes `EmptyState(...)`; keep the filter-chip row above it.
- Connections: the existing `Center(child: Text('No saved connections — tap + to add one.'))` becomes `EmptyState(..., action: FilledButton.icon(...))`.

## 6. Data flow & error handling
- No data/logic change. `.when(loading/error/data)` branches preserved; only the `data`-with-empty-list rendering changes. The Connections action reuses the same `Navigator.push(ConnectionScreen())` as the FAB.

## 7. File structure
```
app/lib/src/ui/widgets/resource_widgets.dart    # + EmptyState
app/lib/src/ui/containers_screen.dart            # empty branch
app/lib/src/ui/images_screen.dart                # empty branch
app/lib/src/ui/networks_screen.dart              # empty branch
app/lib/src/ui/volumes_screen.dart               # empty branch
app/lib/src/ui/events_screen.dart                # empty branch (replaces plain text)
app/lib/src/ui/profiles_screen.dart              # empty branch (+ Add connection action)
app/test/ui/widgets/resource_widgets_test.dart   # + EmptyState test
app/test/ui/...                                   # screen empty-state assertions where practical
```

## 8. Testing
- `EmptyState`: renders the title, the message (when given), the icon, and the action (when given); omits message/action when null.
- A screen with an empty list renders an `EmptyState` (e.g. Connections with no profiles shows "No connections" + the Add button; an empty Events list shows "No events yet"). Keep existing non-empty + navigation tests green; update the Connections empty test (which asserted the old "No saved connections" text) to the new `EmptyState`.
- Full suite green; analyzer clean.

## 9. Dependencies
None new.

## 10. Open questions / to confirm during planning
- Whether Containers/Images/Networks/Volumes have existing empty-list tests (likely not — they're currently blank); add a minimal empty-state test for at least Connections + Events (which had text) and optionally one list screen. Confirm during planning by reading the tests.
