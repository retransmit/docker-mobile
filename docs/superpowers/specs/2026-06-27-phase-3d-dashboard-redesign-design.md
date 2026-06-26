# docker-mobile Phase 3D — System Dashboard Redesign — Design Spec

**Date:** 2026-06-27
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 3A theme + 3B row widgets + 3C detail (on `main`). Third per-screen redesign slice.

---

## 1. Summary

Phase 3D restructures `SystemScreen` from three flat `_kv` cards into a **2×2 metric grid** of stat tiles (Containers / Images / Volumes / Disk) at the top, followed by styled **Daemon** and **Disk usage** detail cards. Adds a reusable `StatCard`. Presentational only — the prune flow, disconnect, Events action, providers, and models are unchanged.

## 2. Goals / Non-goals

**Goals**
- A reusable `StatCard` (tinted icon + big value + label + optional sub) in `widgets/resource_widgets.dart`.
- A **2×2 metric grid** at the top of `SystemScreen`: Containers (running / total), Images (count), Volumes (count), Disk (total size).
- **Daemon** detail card restyled (label-above-value), **Disk usage** card with sizes in `MonoText`.

**Non-goals (out of scope)**
- Any change to `_prune`/`_pruneDialog`, `disconnect`, the Events navigation, providers, or models.
- Charts/graphs of disk usage (later slice handles chart polish); empty states (later slice).
- New dependencies.

## 3. Scope decisions (locked)

- **Presentational restructure of `system_screen.dart`** + one new shared widget (`StatCard`). Same data, same prune/disconnect/Events logic and dialogs.
- **Metric grid** = a 2×2 layout (two `Row`s of two `Expanded` `StatCard`s) inside the existing `ListView`:
  - **Containers** — value `info.containersRunning`, label "Containers", sub `"of ${info.containers} total"`, icon `Icons.inventory_2`.
  - **Images** — value `${info.images}`, label "Images", icon `Icons.layers`.
  - **Volumes** — value `${df.volumes.count}`, label "Volumes", icon `Icons.storage`.
  - **Disk** — value `_humanSize(df.total)`, label "Disk used", icon `Icons.pie_chart` (or `Icons.storage`), sub null.
- **Daemon card** keeps all current fields (Version, API, OS/Arch, Kernel, CPUs, Memory, Storage driver) but uses a label-above-value row (muted label, value below) — replacing the fixed-width `_kv`.
- **Disk usage card** keeps the per-type breakdown (`images/containers/volumes/buildCache` with count) + Total; the size values render via `MonoText`.
- **System prune** button and the app-bar **refresh / Events / Disconnect** actions (+ the disconnect confirm dialog and `_pruneDialog`) are unchanged.
- The `_humanSize` helper is reused as-is.

## 4. Architecture

```
SystemScreen (unchanged shell: AppBar actions + dash.when(...))
  data: (d) -> Column:
    Expanded( ListView( padding 16:
      _MetricGrid(info, df)         // 2x2 StatCards
      _DaemonCard(info, version)    // styled detail card (label-above-value)
      _DiskCard(df)                 // breakdown + total, sizes in MonoText
    ))
    System prune button (unchanged)

widgets/resource_widgets.dart
  StatCard({icon, value, label, sub?})   // tinted icon + big value + label + optional sub
```

## 5. Components

### 5.1 `StatCard` — `widgets/resource_widgets.dart`
`class StatCard extends StatelessWidget { final IconData icon; final String value; final String label; final String? sub; const StatCard({required this.icon, required this.value, required this.label, this.sub}); }` — a `Card` with: a small tinted icon (in a circle/rounded box using `secondaryContainer`), the **value** in a large/headline weight, the **label** muted, and `sub` (if non-null) as a small muted line. Fixed comfortable height so the grid aligns.

### 5.2 `SystemScreen` body
- Replace the three `_card(...)` calls with: a `_MetricGrid` (two `Row`s of two `Expanded(StatCard(...))` with 12px gaps), then a Daemon detail card and a Disk usage card.
- **Daemon card:** a titled `Card` with label-above-value rows (a small private `_kv2(label, value)` that stacks label muted over value, or reuse a shared `_InfoRow`-style). Keeps all seven fields.
- **Disk card:** a titled `Card`; for each of `df.images/df.containers/df.volumes/df.buildCache` a row `"${c.name} (${c.count})"` → `MonoText(_humanSize(c.size))`; then `Total` → `MonoText(_humanSize(df.total))`.

## 6. Data flow & error handling
- No data/logic change. `dash.when(loading/error/data)` unchanged. The prune `try/catch`, invalidations, snackbars, and the disconnect dialog are untouched.

## 7. File structure
```
app/lib/src/ui/widgets/resource_widgets.dart    # + StatCard
app/lib/src/ui/system_screen.dart               # metric grid + restyled detail cards
app/test/ui/widgets/resource_widgets_test.dart  # + StatCard test
app/test/ui/system_screen_test.dart             # updated to the new structure (kept meaningful)
```

## 8. Testing
- `StatCard`: renders the value + label (+ sub when given) and the icon.
- `SystemScreen`: shows the metric grid values (e.g. running count, images count, volumes count, disk total) as `StatCard`s; the Daemon card still shows version/API/OS; the Disk card still shows the breakdown + total. The **System prune** button is present and still opens `_pruneDialog`; the **Disconnect** and **Events** app-bar actions remain. Update the existing system test to assert the new structure (StatCards) while keeping content + prune/disconnect assertions — not weakened to vacuity.
- Full suite green; analyzer clean.

## 9. Dependencies
None new.

## 10. Open questions / to confirm during planning
- Grid layout mechanism: two `Row`s of `Expanded` `StatCard`s (simplest, robust in a `ListView`) vs `GridView.count(shrinkWrap)`. Default: **two Rows** to avoid `GridView` intrinsic-height friction. Confirm during planning.
- `StatCard` value typography: `headlineSmall`/`titleLarge` weight — pick for legibility in light & dark during planning.
