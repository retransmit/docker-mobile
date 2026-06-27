# docker-mobile Phase 3F — Stats / Chart Polish — Design Spec

**Date:** 2026-06-27
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 3A–3E (on `main`). Fifth and final per-screen redesign slice.

---

## 1. Summary

Phase 3F polishes `ContainerStatsScreen`: the CPU & Memory charts get a big current-value header, a smooth curved line in the theme primary color, and a gradient fill; the Network & Block I/O cards become dual-metric tiles (RX/TX, Read/Write) with monospace values and directional icons. Presentational only — the stats provider/notifier and the CPU/memory max-Y logic are unchanged.

## 2. Goals / Non-goals

**Goals**
- Restyle the chart cards: big value (accent), curved theme-primary line with a gradient fill, taller, no dots.
- Restyle Network & Block I/O into dual-metric tiles (two labeled mono values + directional icons).

**Non-goals (out of scope)**
- Changing the stats provider/`StatsNotifier`, the sampling, the history buffers, or `_cpuMaxY`.
- Adding charts for Network/Block I/O (cumulative counters — kept as value tiles).
- New dependencies (fl_chart already present).

## 3. Scope decisions (locked)

- **Presentational restyle of `container_stats_screen.dart` only.** Same data, same `_cpuMaxY`/`_humanBytes`, same provider.
- **Chart card** (`_chartCard`): a title, a **big current value** (`headlineSmall`, weight 700, `scheme.primary`) with an optional **detail** line (`bodySmall`, muted) beneath, then a ~110px `LineChart`:
  - `isCurved: true`, `barWidth: 3`, color `scheme.primary`, `dotData` off.
  - `belowBarData: BarAreaData(show: true, gradient: vertical from scheme.primary.withValues(alpha: 0.30) → transparent)`.
  - `gridData`/`titlesData`/`borderData` off (clean sparkline). `minY: 0`, `maxY` from the caller (unchanged logic).
  - Signature becomes `_chartCard(BuildContext context, String title, String value, String? detail, List<double> history, double maxY)`.
  - **CPU** call: value `'${cpuPercent.toStringAsFixed(1)} %'`, detail `null`, history `s.cpuHistory`, maxY `_cpuMaxY(s.cpuHistory)`.
  - **Memory** call: value `'${memoryPercent.toStringAsFixed(1)} %'`, detail `'${_humanBytes(memoryUsed)} / ${_humanBytes(memoryLimit)}'`, history `s.memHistory`, maxY `100`.
- **Metric tile** (`_metricCard`): a titled card with a `Row` of two `Expanded` items, each an icon (small, muted) + label (small, muted) + `MonoText(value)`:
  - **Network:** RX (`Icons.arrow_downward`, `_humanBytes(netRx)`), TX (`Icons.arrow_upward`, `_humanBytes(netTx)`).
  - **Block I/O:** Read (`Icons.arrow_downward`, `_humanBytes(blockRead)`), Write (`Icons.arrow_upward`, `_humanBytes(blockWrite)`).
- Reuse `MonoText` from `widgets/resource_widgets.dart`. The "Waiting for stats…" and error branches unchanged.

## 4. Architecture

```
ContainerStatsScreen (unchanged shell + _body)
  _body(context, s):
    _chartCard(context, 'CPU', '<cpu> %', null, s.cpuHistory, _cpuMaxY(...))
    _chartCard(context, 'Memory', '<mem> %', '<used> / <limit>', s.memHistory, 100)
    _metricCard(context, 'Network', RX/TX items)
    _metricCard(context, 'Block I/O', Read/Write items)

  helpers: _chartCard(...), _metricCard(context, title, items)
```
(`_body` gains a `BuildContext` param so the helpers can read the theme; the build method passes `context`.)

## 5. Components

### 5.1 `_chartCard`
A `Card` → title (`titleMedium`/bold), a `Row` value header (`headlineSmall` primary big number; the small detail to its right or beneath), then a 110px `LineChart` styled per §3 (curved primary line + gradient fill, no dots/grid/axes).

### 5.2 `_metricCard`
A `Card` → title, then `Row(children: [Expanded(_metricItem(icon,label,value)), Expanded(_metricItem(...))])`; `_metricItem` = a small `Column`/`Row` with the directional icon (muted), the label (`bodySmall` muted), and `MonoText(value)`.

## 6. Data flow & error handling
- No data/logic change. `s.status == error` and `latest == null` branches preserved. The chart reads `s.cpuHistory`/`s.memHistory` exactly as before; `maxY` from `_cpuMaxY`/`100` unchanged.

## 7. File structure
```
app/lib/src/ui/container_stats_screen.dart    # restyled chart + metric cards
app/test/ui/container_stats_screen_test.dart  # updated assertions, kept meaningful
```
(Reuses `widgets/resource_widgets.dart`; no new files.)

## 8. Testing
- The stats screen still shows the CPU value (e.g. a "%"), the memory percent + the used/limit detail, and the Network RX/TX + Block I/O Read/Write byte values (now via `MonoText`).
- A `LineChart` renders for CPU and Memory (chart present); the screen still handles the `latest == null` ("Waiting for stats…") and error branches.
- Update the existing stats test to the new structure (value header + `MonoText` metrics) while keeping the value assertions; not weakened to vacuity.
- Full suite green; analyzer clean.

## 9. Dependencies
None new (`fl_chart` already present).

## 10. Open questions / to confirm during planning
- Memory value header layout: big percent + small "used / limit" to the right vs beneath — pick whichever wraps cleanly on a narrow phone during planning.
- `BarAreaData` gradient API shape in the installed `fl_chart` (1.2.0): use `gradient:` (LinearGradient) on `BarAreaData`; if the version expects `colors`/`gradientColorStops`, adapt to its constructor and keep the fade-to-transparent intent.
