# docker-mobile Phase 3C — Container Detail Redesign — Design Spec

**Date:** 2026-06-27
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 3A theme + 3B row widgets (on `main`). Second per-screen redesign slice.

---

## 1. Summary

Phase 3C restructures `ContainerDetailScreen` from a flat key/value list + a `Wrap` of buttons into a **status-hero card** (status pill + image + promoted Logs/Exec/Stats), **grouped titled info cards** (Configuration / Networking / Storage / Environment), and a titled **Actions** section (lifecycle buttons restyled, destructive ones in the error color). Presentational only — all actions, dialogs, providers, and navigation unchanged.

## 2. Goals / Non-goals

**Goals**
- A **hero card**: large `StatusPill`, image in `MonoText`, created/uptime; **Logs · Exec · Stats** promoted directly beneath as filled-tonal buttons.
- **Grouped info cards** via small `_InfoCard(title, children)` + `_InfoRow(label, value, {mono})` helpers, replacing the flat `_kv` list. Groups: Configuration, Networking, Storage, Environment (Environment is an expandable, collapsed-by-default section).
- **Actions card**: existing lifecycle buttons (Start/Stop/Restart/Pause/Unpause/Kill/Rename/Remove) restyled — routine as filled/tonal, **Kill & Remove in error color** — under an "Actions" heading.

**Non-goals (out of scope)**
- Any change to action logic, the confirm/rename/remove dialogs, providers, models, or navigation targets.
- Logs/Exec/Stats screen internals (separate; Stats polish is a later slice).
- System dashboard / empty states / chart polish (later slices).
- New dependencies.

## 3. Scope decisions (locked)

- **Presentational restructure of `container_detail_screen.dart` only.** Same data, same `_run`/dialog logic, same nav.
- **Reuse** `StatusPill` + `MonoText` from `widgets/resource_widgets.dart` (3B); `StatusColors` from `app_theme.dart` (3A).
- **Hero status** uses `StatusPill(label, color)` (replaces `_StateBadge`'s dot+text); label = `paused`→"paused", running→`state.status`, else→`state.status`; color via `StatusColors` (paused/running/stopped). Exit code appended to the label when stopped with an exit code (e.g. `exited (137)`).
- **Logs/Exec/Stats promoted** to the hero (top), as `FilledButton.tonalIcon` (or tonal), full-width row — the most-used, read-only actions.
- **Info groups** (only render a card/row when the field is non-empty):
  - **Configuration:** Image (mono), Command (mono, if present), Created (if present), Restart policy (if present).
  - **Networking:** Networks (as `MetaChip`s or comma text), Ports (mono).
  - **Storage:** Mounts (mono, one per line, `(ro)` suffix preserved).
  - **Environment:** env vars (mono, one per line) inside an `ExpansionTile` titled "Environment (N)", collapsed by default; omitted entirely if env is empty.
- **Actions** stay in a `Wrap` (handles variable button count) under an "Actions" card/heading; Kill & Remove use `errorContainer`/`error` styling. All dialogs (`_confirm`/`_renameDialog`/`_removeDialog`) and `_run` unchanged.

## 4. Architecture

```
ContainerDetailScreen (unchanged shell: AppBar + detail.when(...))
  _Body (ConsumerWidget) — restructured ListView:
    _HeroCard(detail)                 -> StatusPill + MonoText(image) + created; then Logs/Exec/Stats tonal buttons
    _InfoCard('Configuration', [ _InfoRow('Image', image, mono), _InfoRow('Command', ...), ... ])
    _InfoCard('Networking', [ networks chips, _InfoRow('Ports', ..., mono) ])
    _InfoCard('Storage', [ _InfoRow('Mounts', ..., mono) ])
    _EnvCard(env)                      -> ExpansionTile (collapsed) of MonoText lines
    _ActionsCard(...)                  -> Wrap of lifecycle buttons (Kill/Remove in error color)

  helpers: _InfoCard(title, children), _InfoRow(label, value, {mono})
  unchanged: _run, _confirm, _renameDialog, _RenameDialog, _removeDialog
```

## 5. Components

### 5.1 `_HeroCard`
A `Card` with: a row of `StatusPill(label, color)` (+ exit-code in label) and, if present, created/uptime as small text; `MonoText(detail.image)` (ellipsis, 1-2 lines). Below the card, a full-width `Row` of three `Expanded` `FilledButton.tonalIcon` — **Logs** (`Icons.article`), **Exec** (`Icons.terminal`), **Stats** (`Icons.monitor_heart`) — each navigating exactly as today (`LogsScreen`/`ExecScreen`/`ContainerStatsScreen`).

### 5.2 `_InfoCard` + `_InfoRow`
- `_InfoCard(String title, List<Widget> children)` — a `Card` with a bold title + a `Column` of rows.
- `_InfoRow(String label, String value, {bool mono = false})` — a label (fixed width, muted) + the value (`MonoText` when `mono`, else `Text`), wrapping. Reused across the groups.

### 5.3 `_EnvCard`
An `ExpansionTile` (inside a `Card`) titled `Environment (${env.length})`, `initiallyExpanded: false`, body = a `Column` of `MonoText` lines (one per env var). Rendered only when `env.isNotEmpty`.

### 5.4 `_ActionsCard`
The existing lifecycle `Wrap` moved under an "Actions" titled `Card`. Buttons: Start/Stop/Restart/Pause/Unpause as `FilledButton`/`FilledButton.tonal`; **Kill** and **Remove** styled with `colorScheme.error`/`errorContainer`; **Rename** as `OutlinedButton`. The `onPressed` handlers, confirm/rename/remove dialogs, and `_run` calls are copied verbatim.

## 6. Data flow & error handling
- No data/logic change. `detail.when(loading/error/data)` unchanged; `_run` still invalidates `containerDetailProvider`/`containersProvider` and shows the snackbars. `context.mounted` guards preserved.

## 7. File structure
```
app/lib/src/ui/container_detail_screen.dart   # restructured _Body + new _HeroCard/_InfoCard/_InfoRow/_EnvCard/_ActionsCard
app/test/ui/container_detail_screen_test.dart # updated to the new structure; assertions kept meaningful
```
(No new files; reuses `widgets/resource_widgets.dart`.)

## 8. Testing
- The detail screen still shows the state (`StatusPill` label e.g. "running"), the image value (now in `MonoText`), and the lifecycle button labels for the current state.
- **Logs/Exec/Stats** buttons present and still navigate to `LogsScreen`/`ExecScreen`/`ContainerStatsScreen` (tap → route pushed).
- The **Environment** section is collapsed by default (env values not visible until expanded) and expands to show them; rendered only when env is non-empty.
- Lifecycle actions still work: a running container shows Stop/Restart/Pause/Kill/Rename/Remove; Remove opens the remove dialog (logic unchanged). Update any test asserting the old flat `_kv`/`_StateBadge` structure to the new cards/pill while keeping the content + navigation + action assertions (not weakened to vacuity).
- Full suite green; analyzer clean.

## 9. Dependencies
None new.

## 10. Open questions / to confirm during planning
- `FilledButton.tonalIcon` availability in Flutter 3.44 (stable); if absent, use `FilledButton.tonal` with a `Row(icon,label)` or `OutlinedButton.icon`. Keep three equal-width buttons.
- Networks rendering: small `MetaChip`s vs a comma list — default to `MetaChip`s when few, comma `Text` fallback. Confirm during planning.
