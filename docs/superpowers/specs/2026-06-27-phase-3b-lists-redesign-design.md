# docker-mobile Phase 3B — Lists & Rows Redesign — Design Spec

**Date:** 2026-06-27
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 3A theme foundation (on `main`). First per-screen redesign slice; container-detail / dashboard / empty-states / charts follow.

---

## 1. Summary

Phase 3B redesigns the five list screens (Connections, Containers, Images, Networks, Volumes) on top of the new M3 Expressive theme: each row becomes a tonal **card** with a **leading avatar**, clearer hierarchy, **status pills**, **chips**, and **monospace** for technical strings (IDs, image refs, ports, hashes, mountpoints). Presentational only — no data/logic changes.

## 2. Goals / Non-goals

**Goals**
- Three reusable widgets in `lib/src/ui/widgets/resource_widgets.dart`: `LeadingAvatar`, `StatusPill`, `MonoText`.
- Redesigned rows for `ContainersScreen`, `ProfilesScreen`, `ImagesScreen`, `NetworksScreen`, `VolumesScreen` using them (tonal card + avatar + pill/chip + mono).

**Non-goals (this slice → later slices)**
- Container detail / System dashboard / empty states / chart polish (separate slices).
- Any provider/model/API change; sort/search/grouping; row swipe actions.
- New dependencies.

## 3. Scope decisions (locked)

- **Presentational only:** the data shown is unchanged (same `Text` for name/host/image, etc.), so content-asserting tests keep passing; only the row widget tree changes.
- **Row container:** each list item is a tonal `Card` (theme `cardTheme`) with comfortable padding; the list keeps `ListView`/`ListView.builder`.
- **Leading:** `LeadingAvatar` (rounded ~12-radius container, tinted background, type/state icon) replaces the bare leading `Icon`.
- **Status:** containers show a `StatusPill` (dot + label) colored via `StatusColors` (running / paused / stopped-for-everything-else); the play/stop leading color also uses `StatusColors`.
- **Monospace:** `MonoText` (system `monospace`) for image refs, container/image short IDs, ports, volume names/hashes, mountpoints — anything machine-ish; human names stay in the default face.
- **Chips:** small `Chip`/label for kind (Connections), driver/scope (Networks/Volumes), size (Images) where it reads as metadata.
- **Tap/▼ behavior preserved:** row `onTap`/`PopupMenuButton`/navigation unchanged.

## 4. Architecture

```
lib/src/ui/widgets/resource_widgets.dart
  LeadingAvatar({icon, background?, foreground?})   -> rounded tinted icon container
  StatusPill({label, color})                         -> dot + label filled pill
  MonoText(text, {style?, maxLines?, overflow?})     -> monospace Text

ContainersScreen / ProfilesScreen / ImagesScreen / NetworksScreen / VolumesScreen
  ListView( Card( Row/ListTile( LeadingAvatar + title + MonoText subtitle + StatusPill/Chip + trailing ) ) )
```

## 5. Components

### 5.1 Shared widgets — `lib/src/ui/widgets/resource_widgets.dart`
- `class LeadingAvatar extends StatelessWidget { final IconData icon; final Color? background; final Color? foreground; const LeadingAvatar({required this.icon, this.background, this.foreground}); }` — a ~44px rounded (radius 12) `Container` filled with `background ?? colorScheme.secondaryContainer`, centered `Icon(icon, color: foreground ?? onSecondaryContainer)`.
- `class StatusPill extends StatelessWidget { final String label; final Color color; const StatusPill({required this.label, required this.color}); }` — a `StadiumBorder`-shaped container with a tinted background (`color.withValues(alpha: 0.16)` or a container tone), a small filled dot in `color`, and the label in `color`/onSurface.
- `class MonoText extends StatelessWidget { final String text; final TextStyle? style; final int? maxLines; final TextOverflow? overflow; const MonoText(this.text, {...}); }` — `Text(text, style: (style ?? DefaultTextStyle).copyWith(fontFamily: 'monospace'), maxLines, overflow)`.

### 5.2 Screen rows
- **ContainersScreen:** card row → `LeadingAvatar(icon: running?play:stop, background: StatusColors tint)`, title = name (bold), subtitle = `MonoText(image)` + uptime, trailing = `StatusPill(state)`. State→label/color: `running`→running/"running"; `paused`→paused/"paused"; else→stopped/the raw state.
- **ProfilesScreen:** card row → `LeadingAvatar(icon by kind)`, title = name, subtitle = `MonoText(host)`, a small kind `Chip` (agent/tls/ssh), trailing = the existing `PopupMenuButton`.
- **ImagesScreen:** card row → `LeadingAvatar(Icons.layers)`, title = repo:tag, subtitle = `MonoText(short id)`, trailing = a size `Chip` (e.g. "178.7 MB").
- **NetworksScreen:** card row → `LeadingAvatar(Icons.hub)`, title = name, subtitle = driver·scope (driver as a small `Chip`, scope mono/plain).
- **VolumesScreen:** card row → `LeadingAvatar(Icons.storage)`, title = name (mono if it's a hash), subtitle = `MonoText(mountpoint, maxLines:1, ellipsis)`, trailing = driver `Chip`.

## 6. Data flow & error handling
- No data changes; `.when(loading/error/data)` and the providers are untouched. Loading/error states unchanged (empty-state redesign is a later slice).
- The widgets are pure/stateless; theming via `Theme.of(context)`/`StatusColors.of(context)`.

## 7. File structure
```
app/lib/src/ui/widgets/resource_widgets.dart        # LeadingAvatar + StatusPill + MonoText
app/lib/src/ui/containers_screen.dart               # redesigned rows
app/lib/src/ui/profiles_screen.dart                 # redesigned rows
app/lib/src/ui/images_screen.dart                   # redesigned rows
app/lib/src/ui/networks_screen.dart                 # redesigned rows
app/lib/src/ui/volumes_screen.dart                  # redesigned rows
app/test/...                                          # widget tests for the shared widgets + screens stay green
```

## 8. Testing
- `LeadingAvatar`/`StatusPill`/`MonoText`: render with given icon/label/color/text; `MonoText` applies a `monospace` font family; `StatusPill` shows its label.
- Each redesigned screen still renders its data (name/host/image/size text findable) and now also shows the new bits (e.g. `ContainersScreen` shows a `StatusPill` with "running"; `ProfilesScreen` shows the kind chip). Update any test that asserted a removed structure (e.g. a bare leading `Icon` color) to assert via the new widgets, keeping the content assertions.
- Tap/navigation tests (container row → detail, profile tap → launch, FAB → create) remain green.
- Full suite green; analyzer clean.

## 9. Dependencies
None new.

## 10. Open questions / to confirm during planning
- Whether to keep `ListTile` inside the `Card` (simplest; `ListTile` handles leading/title/subtitle/trailing + tap) vs a custom `Row` for finer control. Default: **`ListTile` inside a `Card`** for containers/connections (keeps tap + the menu trivial), custom `Row` only where the trailing layout needs it.
- Exact `StatusPill` tint (alpha-over-color vs a fixed container tone) — confirm contrast in light & dark during planning.
- Volume "name": Docker anonymous volumes are long hashes — render with `MonoText(maxLines:1, ellipsis)`; named volumes render normally.
