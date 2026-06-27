# Phase 3F — Stats / Chart Polish — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Polish the stats screen — big-value gradient-filled curved charts for CPU/Memory and dual-metric tiles for Network/Block I/O.

**Architecture:** Restyle `container_stats_screen.dart`: `_chartCard` gets a big value header + a curved theme-primary line with a gradient fill; `_numberCard` is replaced by `_metricCard` (two labeled mono values + directional icons). The stats provider/notifier and `_cpuMaxY` are unchanged.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `fl_chart` 1.2.0, `flutter_riverpod` (all existing).

## Global Constraints

- **Presentational restyle of `container_stats_screen.dart` only.** No change to the stats provider/`StatsNotifier`, sampling, history buffers, `_cpuMaxY`, or `_humanBytes`. No new dependency.
- **Reuse** `MonoText` from `widgets/resource_widgets.dart`. Charts use `scheme.primary` (+ gradient), not hardcoded colors.
- `_body` gains a `BuildContext` param so helpers read the theme; `build` passes `context`.
- **Chart card:** big value `headlineSmall`/w700/`scheme.primary` + optional muted detail; 110px `LineChart` `isCurved: true`, `barWidth: 3`, `color: scheme.primary`, `dotData` off, `belowBarData` vertical gradient `primary@0.30 → primary@0.0`, grid/titles/border/touch off, `minY:0`, caller `maxY`.
- **CPU** call: value `'${cpuPercent.toStringAsFixed(1)} %'`, detail `null`. **Memory** call: value `'${memoryPercent.toStringAsFixed(1)} %'`, detail `'${_humanBytes(memoryUsed)} / ${_humanBytes(memoryLimit)}'`, maxY `100`.
- **Metric tile:** Network = RX (`Icons.arrow_downward`) / TX (`Icons.arrow_upward`); Block I/O = Read (`Icons.arrow_downward`) / Write (`Icons.arrow_upward`); values via `MonoText`.
- **Flutter/fl_chart APIs:** `Color.withValues(alpha:)`; `BarAreaData(gradient: LinearGradient(...))` and `LineChartBarData.color` exist in fl_chart 1.2.0 — if a member differs, adapt to the installed constructor keeping the fade-to-transparent fill.
- **Existing stats test stays meaningful:** update to the new structure while keeping the value assertions; never weaken to vacuity.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/ui/container_stats_screen.dart    # restyled chart cards (Task 1) + metric tiles (Task 2)
app/test/ui/container_stats_screen_test.dart   # updated assertions, kept meaningful
```

---

## Task 1: Chart-card polish

**Files:**
- Modify: `app/lib/src/ui/container_stats_screen.dart` (`_body` context + value/detail split; restyle `_chartCard`)
- Test: `app/test/ui/container_stats_screen_test.dart`

**Interfaces:**
- Produces: `_chartCard(BuildContext context, String title, String value, String? detail, List<double> history, double maxY)`; `_body(BuildContext context, StatsState s)`.

- [ ] **Step 1: Read the current test**

Read `app/test/ui/container_stats_screen_test.dart` to learn its fake `statsProvider` override + asserted values (CPU %, memory, etc.).

- [ ] **Step 2: Update the test for the new chart structure (failing)**

In `app/test/ui/container_stats_screen_test.dart`, keep the setup and ensure these assertions (adjust the numbers to the fixture's `latest`):
```dart
  // CPU value header (percentage) + a chart render
  expect(find.textContaining('%'), findsWidgets);
  expect(find.byType(LineChart), findsNWidgets(2)); // CPU + Memory
  // memory detail (used / limit) still shows
  expect(find.textContaining('/'), findsWidgets);
```
Add the import `import 'package:fl_chart/fl_chart.dart';` if not present.

- [ ] **Step 3: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/container_stats_screen_test.dart`
Expected: FAIL or PASS depending on prior assertions — if it already passes, tighten to `find.byType(LineChart)` count `2` and a `headlineSmall` value; the intent is the test reflects the new big-value chart. (If the old test asserted the combined memory string `'27.3 MB / 7.42 GB  (0.4 %)'` it will FAIL after Step 4 since the format splits.)

- [ ] **Step 4: Restyle `_chartCard` + thread context through `_body`**

In `app/lib/src/ui/container_stats_screen.dart`, change the `build` body call to `body: _body(context, s)`, change `_body`'s signature to `Widget _body(BuildContext context, StatsState s)`, and update the two `_chartCard` calls + the method. Replace the `_body` method and the `_chartCard` method with:
```dart
  Widget _body(BuildContext context, StatsState s) {
    if (s.status == StatsStatus.error) return Center(child: Text('Error: ${s.error}'));
    final latest = s.latest;
    if (latest == null) return const Center(child: Text('Waiting for stats…'));
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _chartCard(context, 'CPU', '${latest.cpuPercent.toStringAsFixed(1)} %', null, s.cpuHistory, _cpuMaxY(s.cpuHistory)),
        const SizedBox(height: 12),
        _chartCard(
          context,
          'Memory',
          '${latest.memoryPercent.toStringAsFixed(1)} %',
          '${_humanBytes(latest.memoryUsed)} / ${_humanBytes(latest.memoryLimit)}',
          s.memHistory,
          100,
        ),
        const SizedBox(height: 12),
        _numberCard('Network', 'RX ${_humanBytes(latest.netRx)}   ·   TX ${_humanBytes(latest.netTx)}'),
        const SizedBox(height: 12),
        _numberCard('Block I/O', 'Read ${_humanBytes(latest.blockRead)}   ·   Write ${_humanBytes(latest.blockWrite)}'),
      ],
    );
  }

  Widget _chartCard(BuildContext context, String title, String value, String? detail, List<double> history, double maxY) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(value, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, color: scheme.primary)),
                if (detail != null) ...[
                  const SizedBox(width: 8),
                  Expanded(child: Text(detail, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant))),
                ],
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 110,
              child: LineChart(LineChartData(
                minY: 0,
                maxY: maxY,
                titlesData: const FlTitlesData(show: false),
                gridData: const FlGridData(show: false),
                borderData: FlBorderData(show: false),
                lineTouchData: const LineTouchData(enabled: false),
                lineBarsData: [
                  LineChartBarData(
                    spots: [for (var i = 0; i < history.length; i++) FlSpot(i.toDouble(), history[i])],
                    isCurved: true,
                    preventCurveOverShooting: true,
                    barWidth: 3,
                    color: scheme.primary,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [scheme.primary.withValues(alpha: 0.30), scheme.primary.withValues(alpha: 0.0)],
                      ),
                    ),
                  ),
                ],
              )),
            ),
          ],
        ),
      ),
    );
  }
```
(`_numberCard` is left unchanged here; it is replaced in Task 2.)

- [ ] **Step 5: Run the stats test + full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; all tests pass. (If the old test asserted the combined memory string, update it to assert the percent value + the `used / limit` detail separately.)

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/ui/container_stats_screen.dart app/test/ui/container_stats_screen_test.dart
git commit -m "feat(app): polish CPU/Memory charts (big value, curved gradient theme line)"
```

---

## Task 2: Network + Block I/O metric tiles

**Files:**
- Modify: `app/lib/src/ui/container_stats_screen.dart` (replace `_numberCard` with `_metricCard`)
- Test: `app/test/ui/container_stats_screen_test.dart`

**Interfaces:**
- Consumes: `MonoText` (3B), `_body` (Task 1).
- Produces: `_metricCard(BuildContext context, String title, List<(String, IconData, String)> items)`.

- [ ] **Step 1: Add the failing assertion**

In `app/test/ui/container_stats_screen_test.dart`, assert the Network/Block I/O byte values render (adjust to the fixture's `netRx`/`netTx`/`blockRead`/`blockWrite`), e.g.:
```dart
  expect(find.text('RX'), findsOneWidget);
  expect(find.text('TX'), findsOneWidget);
  expect(find.text('Read'), findsOneWidget);
  expect(find.text('Write'), findsOneWidget);
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/container_stats_screen_test.dart`
Expected: FAIL — the old `_numberCard` renders "RX … · TX …" as one string, so `find.text('RX')` finds nothing.

- [ ] **Step 3: Replace `_numberCard` with `_metricCard`**

In `app/lib/src/ui/container_stats_screen.dart` add `import 'widgets/resource_widgets.dart';`. In `_body`, replace the two `_numberCard(...)` calls with:
```dart
        _metricCard(context, 'Network', [
          ('RX', Icons.arrow_downward, _humanBytes(latest.netRx)),
          ('TX', Icons.arrow_upward, _humanBytes(latest.netTx)),
        ]),
        const SizedBox(height: 12),
        _metricCard(context, 'Block I/O', [
          ('Read', Icons.arrow_downward, _humanBytes(latest.blockRead)),
          ('Write', Icons.arrow_upward, _humanBytes(latest.blockWrite)),
        ]),
```
Delete the `_numberCard` method and add `_metricCard`:
```dart
  Widget _metricCard(BuildContext context, String title, List<(String, IconData, String)> items) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final (label, icon, value) in items)
                  Expanded(
                    child: Row(
                      children: [
                        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
                        const SizedBox(width: 6),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(label, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                            MonoText(value, style: text.bodyMedium),
                          ],
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
```

- [ ] **Step 4: Run the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; all tests pass (RX/TX/Read/Write labels + the byte values via `MonoText` now render).

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/ui/container_stats_screen.dart app/test/ui/container_stats_screen_test.dart
git commit -m "feat(app): Network + Block I/O dual-metric tiles (mono values, directional icons)"
```

---

## Self-Review

**1. Spec coverage:**
- Chart card big value + curved theme-primary gradient line → Task 1. ✓
- CPU (no detail) + Memory (percent + used/limit detail) calls → Task 1. ✓
- Network/Block I/O dual-metric tiles (mono + directional icons) → Task 2. ✓
- `_cpuMaxY`/provider/`_humanBytes` unchanged → both tasks leave them. ✓
- Out of scope (provider/sampling/new charts) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete. The fixture-number + fl_chart-API adaptation notes are bounded, explicit instructions.

**3. Type consistency:** `_chartCard(BuildContext, String, String, String?, List<double>, double)` and `_body(BuildContext, StatsState)` (Task 1) match their call sites. `_metricCard(BuildContext, String, List<(String, IconData, String)>)` (Task 2) matches its calls. `MonoText(text, {style})` (3B) used in `_metricCard`. `latest.cpuPercent/memoryPercent/memoryUsed/memoryLimit/netRx/netTx/blockRead/blockWrite`, `s.cpuHistory/memHistory`, `_cpuMaxY`, `_humanBytes`, `StatsStatus.error` are the screen's existing members, reused verbatim. ✓
