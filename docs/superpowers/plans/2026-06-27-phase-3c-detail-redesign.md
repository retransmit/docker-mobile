# Phase 3C — Container Detail Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the container detail screen into a status-hero card + promoted Logs/Exec/Stats + grouped info cards + a titled Actions section.

**Architecture:** Rewrite `_Body` in `container_detail_screen.dart` to render a hero `Card` (StatusPill + mono image), a Logs/Exec/Stats tonal-button row, grouped `_InfoCard`s (Configuration/Networking/Storage) + an expandable Environment card, then the lifecycle buttons under an "Actions" card. Reuses `StatusPill`/`MonoText` (3B). Presentational only.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod` (all existing).

## Global Constraints

- **Presentational restructure of `container_detail_screen.dart` only.** No change to `_run`, the confirm/rename/remove dialogs, providers, models, or navigation targets (`LogsScreen`/`ExecScreen`/`ContainerStatsScreen`).
- **Reuse** `StatusPill` + `MonoText` from `widgets/resource_widgets.dart`; `StatusColors` from `theme/app_theme.dart`.
- **Hero pill label:** `s.paused ? 'paused' : (!s.running && s.exitCode != null ? '${s.status} (exit ${s.exitCode})' : s.status)`; color = `paused`→`StatusColors.paused`, `running`→`.running`, else→`.stopped`. Image shown **only** in the hero (not duplicated in Configuration).
- **Logs/Exec/Stats** promoted to a full-width 3-button row right under the hero (the old bottom Row is removed); each navigates exactly as before.
- **Info groups** render a card/row only when the field is non-empty: Configuration (Created, Command, Restart policy), Networking (Networks, Ports), Storage (Mounts), Environment (`ExpansionTile`, collapsed, only if env non-empty).
- **Actions:** the existing lifecycle `Wrap` moves under an "Actions" titled card; routine buttons `FilledButton`/`FilledButton.tonal`, **Kill & Remove** styled with `colorScheme.error`/`errorContainer`, Rename `OutlinedButton`. Handlers/dialogs verbatim.
- **Flutter 3.44 APIs:** `FilledButton.tonalIcon` / `FilledButton.tonal` exist; if a member differs, adapt minimally and keep three equal-width primary buttons.
- **Existing detail test stays meaningful:** update it to the new structure (pill/cards) while keeping content + navigation + action assertions; never weaken to vacuity. The image now appears once (hero) — assert with `findsOneWidget` or `findsWidgets` as appropriate.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/ui/container_detail_screen.dart     # rewritten _Body + _InfoCard/_InfoRow/_EnvCard helpers (Task 1); Actions card (Task 2)
app/test/ui/container_detail_screen_test.dart    # updated assertions, kept meaningful
```

---

## Task 1: Hero card + promoted actions + grouped info cards

**Files:**
- Modify: `app/lib/src/ui/container_detail_screen.dart` (rewrite `_Body.build`; add `_InfoCard`/`_InfoRow`/`_EnvCard`; remove old `_StateBadge` + `_kv` + old Logs/Exec/Stats Row + Divider; keep the lifecycle `Wrap` as-is at the bottom for now)
- Test: `app/test/ui/container_detail_screen_test.dart`

**Interfaces:**
- Consumes: `StatusPill({label, color})`, `MonoText(text, {style, maxLines, overflow})` (3B); `StatusColors.of(context)` (3A).
- Produces (private to the file): `_InfoCard(String title, List<Widget> children)`, `_InfoRow(String label, String value, {bool mono})`, `_EnvCard({required List<String> env})`.

- [ ] **Step 1: Read the current test + screen**

Read `app/test/ui/container_detail_screen_test.dart` and `app/lib/src/ui/container_detail_screen.dart` fully so the rewrite preserves every behavior the test relies on (the fake client, the `containerDetailProvider` override, the asserted texts/buttons).

- [ ] **Step 2: Update the test to the new structure (failing)**

In `app/test/ui/container_detail_screen_test.dart`, keep the existing setup/overrides. Ensure these assertions exist (add/adjust, keeping any existing meaningful ones):
```dart
  // hero shows the status via a StatusPill and the image via MonoText
  expect(find.byType(StatusPill), findsOneWidget);
  expect(find.textContaining('nginx'), findsWidgets); // the image ref (adjust to the fixture's image)
  // primary actions present and grouped at the top
  expect(find.widgetWithText(FilledButton, 'Logs'), findsOneWidget);
  expect(find.widgetWithText(FilledButton, 'Exec'), findsOneWidget);
  expect(find.widgetWithText(FilledButton, 'Stats'), findsOneWidget);
  // Environment is collapsed by default: an env value is NOT visible until expanded (only if the fixture has env)
```
Add the import `import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';`. (If the fixture's image/env differ, match them; if `FilledButton.tonalIcon` is used, `find.widgetWithText(FilledButton, 'Logs')` still matches since tonalIcon yields a FilledButton.)

- [ ] **Step 3: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/container_detail_screen_test.dart`
Expected: FAIL — no `StatusPill`/`FilledButton` Logs yet (old screen uses `_StateBadge`/`OutlinedButton`).

- [ ] **Step 4: Rewrite `_Body.build` + add helpers**

In `app/lib/src/ui/container_detail_screen.dart`: add `import 'widgets/resource_widgets.dart';`. Replace the `_Body.build` method body's `ListView(...)` with the following (keep the existing `_run`, dialogs, and class signature). Replace everything from `return ListView(` through its closing `);` with:
```dart
    final client = ref.read(dockerClientProvider)!;
    final s = detail.state;
    final status = StatusColors.of(context);
    final color = s.paused ? status.paused : (s.running ? status.running : status.stopped);
    final label = s.paused
        ? 'paused'
        : (!s.running && s.exitCode != null ? '${s.status} (exit ${s.exitCode})' : s.status);
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Hero
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusPill(label: label, color: color),
                const SizedBox(height: 12),
                MonoText(detail.image, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodyMedium),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Promoted read-only actions
        Row(
          children: [
            Expanded(child: FilledButton.tonalIcon(
              icon: const Icon(Icons.article),
              label: const Text('Logs'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => LogsScreen(containerId: containerId, containerName: containerName))),
            )),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.tonalIcon(
              icon: const Icon(Icons.terminal),
              label: const Text('Exec'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ExecScreen(containerId: containerId, containerName: containerName))),
            )),
            const SizedBox(width: 8),
            Expanded(child: FilledButton.tonalIcon(
              icon: const Icon(Icons.monitor_heart),
              label: const Text('Stats'),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ContainerStatsScreen(containerId: containerId, containerName: containerName))),
            )),
          ],
        ),
        const SizedBox(height: 16),
        // Configuration
        if (detail.created.isNotEmpty || detail.command.isNotEmpty || detail.restartPolicy.isNotEmpty)
          _InfoCard('Configuration', [
            if (detail.created.isNotEmpty) _InfoRow('Created', detail.created),
            if (detail.command.isNotEmpty) _InfoRow('Command', detail.command, mono: true),
            if (detail.restartPolicy.isNotEmpty) _InfoRow('Restart policy', detail.restartPolicy),
          ]),
        // Networking
        if (detail.networks.isNotEmpty || detail.ports.isNotEmpty)
          _InfoCard('Networking', [
            if (detail.networks.isNotEmpty) _InfoRow('Networks', detail.networks.join(', ')),
            if (detail.ports.isNotEmpty)
              _InfoRow('Ports',
                  detail.ports.map((p) => '${p.publicPort != null ? '${p.publicPort}->' : ''}${p.privatePort}/${p.type}').join(', '),
                  mono: true),
          ]),
        // Storage
        if (detail.mounts.isNotEmpty)
          _InfoCard('Storage', [
            _InfoRow('Mounts', detail.mounts.map((m) => '${m.source}:${m.destination}${m.rw ? '' : ' (ro)'}').join('\n'), mono: true),
          ]),
        // Environment (collapsed)
        if (detail.env.isNotEmpty) _EnvCard(env: detail.env),
        const SizedBox(height: 8),
        // Lifecycle actions (restyled in Task 2)
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (!s.running)
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.startContainer(containerId), 'Started'), child: const Text('Start')),
            if (s.running && !s.paused) ...[
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.stopContainer(containerId), 'Stopped'), child: const Text('Stop')),
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.restartContainer(containerId), 'Restarted'), child: const Text('Restart')),
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.pauseContainer(containerId), 'Paused'), child: const Text('Pause')),
            ],
            if (s.paused)
              ElevatedButton(onPressed: () => onRun(context, ref, () => client.unpauseContainer(containerId), 'Unpaused'), child: const Text('Unpause')),
            if (s.running)
              ElevatedButton(
                onPressed: () async {
                  if (await _confirm(context, 'Kill container?', 'Sends SIGKILL immediately.') && context.mounted) {
                    await onRun(context, ref, () => client.killContainer(containerId), 'Killed');
                  }
                },
                child: const Text('Kill'),
              ),
            OutlinedButton(
              onPressed: () async {
                final name = await _renameDialog(context, containerName);
                if (name != null && name.isNotEmpty && context.mounted) {
                  await onRun(context, ref, () => client.renameContainer(containerId, name), 'Renamed');
                }
              },
              child: const Text('Rename'),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.errorContainer),
              onPressed: () async {
                final opts = await _removeDialog(context);
                if (opts != null && context.mounted) {
                  await onRun(context, ref, () => client.removeContainer(containerId, force: opts.$1, removeVolumes: opts.$2), 'Removed');
                }
              },
              child: const Text('Remove'),
            ),
          ],
        ),
      ],
    );
```
Then **delete** the old `_kv` method (in `_Body`) and the `_StateBadge` class (no longer used), and add these helper classes at the end of the file (after `_removeDialog`):
```dart
class _InfoCard extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _InfoCard(this.title, this.children);

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            ...children,
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final bool mono;
  const _InfoRow(this.label, this.value, {this.mono = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 2),
          mono
              ? MonoText(value, style: text.bodyMedium)
              : Text(value, style: text.bodyMedium),
        ],
      ),
    );
  }
}

class _EnvCard extends StatelessWidget {
  final List<String> env;
  const _EnvCard({required this.env});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          title: Text('Environment (${env.length})', style: text.titleMedium),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          expandedCrossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final e in env) MonoText(e, style: text.bodySmall)],
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: Run the detail test + the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; the updated detail test passes; the whole suite green. (Fix the test's expected image/env strings to match the fixture if needed; keep assertions meaningful.)

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/ui/container_detail_screen.dart app/test/ui/container_detail_screen_test.dart
git commit -m "feat(app): container detail hero card + promoted actions + grouped info cards"
```

---

## Task 2: Actions card (titled section, destructive styling)

**Files:**
- Modify: `app/lib/src/ui/container_detail_screen.dart` (wrap the lifecycle `Wrap` in an "Actions" titled card; restyle buttons)
- Test: `app/test/ui/container_detail_screen_test.dart` (assert the Actions card + buttons)

**Interfaces:**
- Consumes: `_InfoCard` (Task 1).

- [ ] **Step 1: Add the failing assertion**

In `app/test/ui/container_detail_screen_test.dart`, add (for a running-container fixture):
```dart
  expect(find.widgetWithText(Card, 'Actions'), findsOneWidget); // actions live under a titled card
  expect(find.widgetWithText(FilledButton, 'Remove'), findsOneWidget); // Remove is now a FilledButton (error styled)
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/container_detail_screen_test.dart`
Expected: FAIL — no "Actions" card; Remove is still an `ElevatedButton`.

- [ ] **Step 3: Wrap + restyle the actions**

In `_Body.build`, replace the lifecycle `Wrap( ... )` (the whole block added in Task 1) with `_InfoCard('Actions', [ Wrap( ... ) ])`, and change the button widgets:
- Start/Stop/Restart/Pause/Unpause: `ElevatedButton(...)` → `FilledButton.tonal(...)` (same `onPressed`/`child`).
- Kill: `ElevatedButton(...)` → `FilledButton(style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error, foregroundColor: Theme.of(context).colorScheme.onError), onPressed: ..., child: const Text('Kill'))` (same onPressed).
- Rename: keep `OutlinedButton(...)`.
- Remove: `ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: ...errorContainer), ...)` → `FilledButton(style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.errorContainer, foregroundColor: Theme.of(context).colorScheme.onErrorContainer), onPressed: ..., child: const Text('Remove'))` (same onPressed/dialog).

Concretely, the block becomes:
```dart
        _InfoCard('Actions', [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (!s.running)
                FilledButton.tonal(onPressed: () => onRun(context, ref, () => client.startContainer(containerId), 'Started'), child: const Text('Start')),
              if (s.running && !s.paused) ...[
                FilledButton.tonal(onPressed: () => onRun(context, ref, () => client.stopContainer(containerId), 'Stopped'), child: const Text('Stop')),
                FilledButton.tonal(onPressed: () => onRun(context, ref, () => client.restartContainer(containerId), 'Restarted'), child: const Text('Restart')),
                FilledButton.tonal(onPressed: () => onRun(context, ref, () => client.pauseContainer(containerId), 'Paused'), child: const Text('Pause')),
              ],
              if (s.paused)
                FilledButton.tonal(onPressed: () => onRun(context, ref, () => client.unpauseContainer(containerId), 'Unpaused'), child: const Text('Unpause')),
              if (s.running)
                FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError),
                  onPressed: () async {
                    if (await _confirm(context, 'Kill container?', 'Sends SIGKILL immediately.') && context.mounted) {
                      await onRun(context, ref, () => client.killContainer(containerId), 'Killed');
                    }
                  },
                  child: const Text('Kill'),
                ),
              OutlinedButton(
                onPressed: () async {
                  final name = await _renameDialog(context, containerName);
                  if (name != null && name.isNotEmpty && context.mounted) {
                    await onRun(context, ref, () => client.renameContainer(containerId, name), 'Renamed');
                  }
                },
                child: const Text('Rename'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                    backgroundColor: Theme.of(context).colorScheme.errorContainer,
                    foregroundColor: Theme.of(context).colorScheme.onErrorContainer),
                onPressed: () async {
                  final opts = await _removeDialog(context);
                  if (opts != null && context.mounted) {
                    await onRun(context, ref, () => client.removeContainer(containerId, force: opts.$1, removeVolumes: opts.$2), 'Removed');
                  }
                },
                child: const Text('Remove'),
              ),
            ],
          ),
        ]),
```

- [ ] **Step 4: Run the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; all tests pass (the Actions card + Remove FilledButton assertions now pass; existing action/dialog tests still pass — the onPressed logic is unchanged).

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/ui/container_detail_screen.dart app/test/ui/container_detail_screen_test.dart
git commit -m "feat(app): group container lifecycle buttons in an Actions card (destructive styling)"
```

---

## Self-Review

**1. Spec coverage:**
- Hero card (StatusPill + mono image) → Task 1. ✓
- Logs/Exec/Stats promoted to top → Task 1. ✓
- Grouped info cards (Configuration/Networking/Storage) + `_InfoCard`/`_InfoRow` → Task 1. ✓
- Environment expandable, collapsed, only if non-empty (`_EnvCard`) → Task 1. ✓
- Actions titled card with destructive (Kill/Remove) error styling → Task 2. ✓
- Presentational only (dialogs/`_run`/providers/nav unchanged) → Tasks 1/2 copy handlers verbatim. ✓
- Out of scope (dashboard/empty-states/charts) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete. The fixture-string + `FilledButton.tonalIcon` adaptation notes are bounded, explicit instructions.

**3. Type consistency:** `StatusPill({label, color})` + `MonoText(text, {style, maxLines, overflow})` (3B) constructed correctly. `StatusColors.of(context).{paused,running,stopped}` (3A) used in Task 1. `_InfoCard(String, List<Widget>)`, `_InfoRow(String, String, {bool mono})`, `_EnvCard({required List<String> env})` defined in Task 1, used in Tasks 1/2. `onRun`, `_confirm`, `_renameDialog`, `_removeDialog`, `client.*` are the screen's existing members, reused verbatim. ✓
