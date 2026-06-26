# Phase 3D — System Dashboard Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the System screen's three flat key/value cards with a 2×2 metric grid plus styled Daemon and Disk-usage detail cards.

**Architecture:** Add a reusable `StatCard` to `resource_widgets.dart`; rebuild `SystemScreen`'s body as a metric grid (Containers/Images/Volumes/Disk) + a Daemon detail card + a Disk-usage card. The prune flow, disconnect, Events action, providers, and models are untouched.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod` (all existing).

## Global Constraints

- **Presentational restructure of `system_screen.dart`** + one new shared widget (`StatCard`). No change to `_prune`/`_pruneDialog`, `disconnect`, the Events navigation, providers, or models. No new dependency.
- **Reuse** `MonoText` from `widgets/resource_widgets.dart`; reuse the existing `_humanSize` helper as-is.
- **Metric grid** = two `IntrinsicHeight` `Row`s (cross-axis stretch) of two `Expanded` `StatCard`s, 12px gaps: Containers (`info.containersRunning`, sub `of ${info.containers} total`, `Icons.inventory_2`), Images (`${info.images}`, `Icons.layers`), Volumes (`${df.volumes.count}`, `Icons.storage`), Disk (`_humanSize(df.total)`, "Disk used", `Icons.pie_chart`).
- The old **Containers** `_card` is removed (now in the grid). Daemon + Disk-usage cards keep all current fields.
- **Daemon card** rows become label-above-value; **Disk-usage** size values render via `MonoText`.
- **System prune** button + app-bar **refresh/Events/Disconnect** actions (and their dialogs) unchanged.
- **Existing system test stays meaningful:** update to the new structure (StatCards) while keeping content + prune/disconnect assertions; never weaken to vacuity.
- **Flutter 3.44 APIs:** `scheme.secondaryContainer/onSecondaryContainer/onSurfaceVariant`. Adapt minimally if a member differs; keep the styling.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/ui/widgets/resource_widgets.dart    # + StatCard
app/lib/src/ui/system_screen.dart               # metric grid (Task 1) + restyled Daemon/Disk cards (Task 2)
app/test/ui/widgets/resource_widgets_test.dart  # + StatCard test
app/test/ui/system_screen_test.dart             # updated assertions, kept meaningful
```

---

## Task 1: StatCard + metric grid

**Files:**
- Modify: `app/lib/src/ui/widgets/resource_widgets.dart` (add `StatCard`), `app/lib/src/ui/system_screen.dart` (metric grid; remove the Containers `_card`)
- Test: `app/test/ui/widgets/resource_widgets_test.dart`, `app/test/ui/system_screen_test.dart`

**Interfaces:**
- Produces: `class StatCard extends StatelessWidget { const StatCard({required IconData icon, required String value, required String label, String? sub}); }`.

- [ ] **Step 1: Write the failing StatCard test**

Append to `app/test/ui/widgets/resource_widgets_test.dart`:
```dart
  testWidgets('StatCard shows value, label, sub and icon', (tester) async {
    await tester.pumpWidget(_host(const StatCard(icon: Icons.layers, value: '12', label: 'Images', sub: 'of 20')));
    expect(find.text('12'), findsOneWidget);
    expect(find.text('Images'), findsOneWidget);
    expect(find.text('of 20'), findsOneWidget);
    expect(find.byIcon(Icons.layers), findsOneWidget);
  });
```
(The `_host` helper already exists in this file from Phase 3B.)

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/widgets/resource_widgets_test.dart`
Expected: FAIL — `StatCard` undefined.

- [ ] **Step 3: Implement StatCard**

Append to `app/lib/src/ui/widgets/resource_widgets.dart`:
```dart
/// A dashboard metric tile: tinted icon, large value, label, and optional sub.
class StatCard extends StatelessWidget {
  final IconData icon;
  final String value;
  final String label;
  final String? sub;
  const StatCard({super.key, required this.icon, required this.value, required this.label, this.sub});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(10)),
              child: Icon(icon, size: 20, color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: 12),
            Text(value, style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
            Text(label, style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
            if (sub != null) Text(sub!, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run the StatCard test to verify it passes**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/widgets/resource_widgets_test.dart`
Expected: PASS.

- [ ] **Step 5: Add the metric grid to SystemScreen + update its test**

First read `app/test/ui/system_screen_test.dart` to learn its fixture/overrides. Then in `app/lib/src/ui/system_screen.dart` add `import 'widgets/resource_widgets.dart';`, and in the `data: (d) { ... }` builder replace the `ListView`'s `children: [ ... ]` (the three `_card(...)` entries) with:
```dart
                  children: [
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: StatCard(icon: Icons.inventory_2, value: '${info.containersRunning}', label: 'Containers', sub: 'of ${info.containers} total')),
                          const SizedBox(width: 12),
                          Expanded(child: StatCard(icon: Icons.layers, value: '${info.images}', label: 'Images')),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    IntrinsicHeight(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Expanded(child: StatCard(icon: Icons.storage, value: '${df.volumes.count}', label: 'Volumes')),
                          const SizedBox(width: 12),
                          Expanded(child: StatCard(icon: Icons.pie_chart, value: _humanSize(df.total), label: 'Disk used')),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    _card('Daemon', [
                      _kv('Version', info.serverVersion),
                      _kv('API', v.apiVersion),
                      _kv('OS / Arch', '${info.osType} / ${info.architecture}'),
                      _kv('Kernel', info.kernelVersion),
                      _kv('CPUs', '${info.ncpu}'),
                      _kv('Memory', _humanSize(info.memTotal)),
                      _kv('Storage driver', info.storageDriver),
                    ]),
                    _card('Disk usage', [
                      for (final c in [df.images, df.containers, df.volumes, df.buildCache])
                        _kv('${c.name} (${c.count})', _humanSize(c.size)),
                      _kv('Total', _humanSize(df.total)),
                    ]),
                  ],
```
(This removes the old `_card('Containers', ...)` block; Daemon + Disk-usage are unchanged here — they are restyled in Task 2.) In `app/test/ui/system_screen_test.dart`, add the import `import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';` and update/keep assertions so the metric values are asserted via the grid, e.g.:
```dart
  expect(find.byType(StatCard), findsNWidgets(4));
  expect(find.widgetWithText(StatCard, 'Containers'), findsOneWidget);
  expect(find.widgetWithText(StatCard, 'Images'), findsOneWidget);
```
If the existing test asserted the old `Containers` card's "Running"/"Total" rows, replace those with the StatCard assertions (the running count is the StatCard `value`); keep the Daemon version assertion and the prune-button/disconnect assertions.

- [ ] **Step 6: Run the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; all tests pass.

- [ ] **Step 7: Commit**

```bash
git add app/lib/src/ui/widgets/resource_widgets.dart app/lib/src/ui/system_screen.dart app/test/ui/widgets/resource_widgets_test.dart app/test/ui/system_screen_test.dart
git commit -m "feat(app): System dashboard metric grid (StatCard: containers/images/volumes/disk)"
```

---

## Task 2: Daemon + Disk-usage detail-card restyle

**Files:**
- Modify: `app/lib/src/ui/system_screen.dart` (label-above-value Daemon rows; mono sizes in Disk usage)
- Test: `app/test/ui/system_screen_test.dart` (keep content assertions)

**Interfaces:**
- Consumes: `MonoText` (3B), the `_card` helper + the metric grid (Task 1).

- [ ] **Step 1: Add the failing assertion**

In `app/test/ui/system_screen_test.dart`, ensure a disk-size value (from the fixture) is asserted to render via `MonoText`, e.g.:
```dart
  // a disk-usage size renders in monospace (adjust the string to the fixture's df total)
  final sizeText = tester.widget<Text>(find.descendant(of: find.byType(MonoText), matching: find.byType(Text)).first);
  expect(sizeText.style?.fontFamily, 'monospace');
```
(Keep the existing Daemon version + prune assertions.)

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/system_screen_test.dart`
Expected: FAIL — no `MonoText` in the disk card yet.

- [ ] **Step 3: Restyle the Daemon + Disk-usage cards**

In `app/lib/src/ui/system_screen.dart`, replace the `_kv` method with a label-above-value `_kv2` that takes `context` and an optional `mono` flag, and update the Daemon + Disk-usage card row builders to use it. Replace the `_kv` method definition with:
```dart
  Widget _kv2(BuildContext context, String label, String value, {bool mono = false}) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          mono ? MonoText(value, style: text.bodyMedium) : Text(value, style: text.bodyMedium),
        ],
      ),
    );
  }
```
Then update the two card blocks (in the `data:` builder, where `context` is in scope) to call `_kv2`:
```dart
                    _card('Daemon', [
                      _kv2(context, 'Version', info.serverVersion),
                      _kv2(context, 'API', v.apiVersion),
                      _kv2(context, 'OS / Arch', '${info.osType} / ${info.architecture}'),
                      _kv2(context, 'Kernel', info.kernelVersion),
                      _kv2(context, 'CPUs', '${info.ncpu}'),
                      _kv2(context, 'Memory', _humanSize(info.memTotal)),
                      _kv2(context, 'Storage driver', info.storageDriver),
                    ]),
                    _card('Disk usage', [
                      for (final c in [df.images, df.containers, df.volumes, df.buildCache])
                        _kv2(context, '${c.name} (${c.count})', _humanSize(c.size), mono: true),
                      _kv2(context, 'Total', _humanSize(df.total), mono: true),
                    ]),
```
Remove the now-unused old `_kv` method.

- [ ] **Step 4: Run the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; all tests pass (the disk sizes now render via `MonoText`; the Daemon version/fields still show; prune/disconnect unchanged).

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/ui/system_screen.dart app/test/ui/system_screen_test.dart
git commit -m "feat(app): restyle Daemon + Disk-usage cards (label-above-value, mono sizes)"
```

---

## Self-Review

**1. Spec coverage:**
- `StatCard` (tinted icon + value + label + sub) → Task 1. ✓
- 2×2 metric grid (Containers/Images/Volumes/Disk) → Task 1. ✓
- Old Containers `_card` removed → Task 1. ✓
- Daemon detail card label-above-value → Task 2. ✓
- Disk usage sizes in MonoText → Task 2. ✓
- Prune/disconnect/Events/providers unchanged → both tasks leave them untouched. ✓
- Out of scope (charts/empty states) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete. The fixture-string adaptation note is a bounded, explicit instruction.

**3. Type consistency:** `StatCard({icon, value, label, sub?})` (Task 1) constructed identically in the grid. `MonoText(text, {style})` (3B) used in `_kv2` (Task 2). `_humanSize`, `_card`, `info`/`v`/`df` fields (`containersRunning`, `containers`, `images`, `volumes.count`, `total`, `serverVersion`, `apiVersion`, `osType`, `architecture`, `kernelVersion`, `ncpu`, `memTotal`, `storageDriver`, and `df.images/containers/volumes/buildCache` `.name/.count/.size`) are the screen's existing members/model fields, reused verbatim. `_kv2(context, label, value, {mono})` defined in Task 2, used in both cards. ✓
