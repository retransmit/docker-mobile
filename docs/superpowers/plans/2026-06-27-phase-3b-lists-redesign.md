# Phase 3B — Lists & Rows Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Redesign the five list screens into tonal card rows with avatars, status pills, chips, and monospace technical text on top of the new theme.

**Architecture:** Three+one reusable presentational widgets (`LeadingAvatar`, `StatusPill`, `MonoText`, `MetaChip`); each list screen swaps its plain `ListTile` for a `Card`-wrapped row using them. No data/logic changes.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod` (all existing).

## Global Constraints

- **Presentational only:** no provider/model/API/navigation changes; the same data renders (name/host/image text stays findable) — only the row widget tree changes.
- **Row = tonal `Card`** (theme `cardTheme`) wrapping a `ListTile` (keeps leading/title/subtitle/trailing + `onTap`/menu trivial).
- **`LeadingAvatar`** (44px, radius-12, tinted) replaces the bare leading `Icon`; **`StatusPill`** (dot + label, `StatusColors`) for container state; **`MonoText`** (system `monospace`) for image refs/IDs/ports/hashes/mountpoints; **`MetaChip`** (small tonal tag) for kind/driver/scope/size.
- **`StatusColors`** drives container state colors (running/paused/stopped-else). No hardcoded `Colors.green`/`grey`.
- **Flutter 3.44 APIs:** `Color.withValues(alpha:)` (not `withOpacity`); `scheme.surfaceContainerHighest`/`secondaryContainer`/`onSecondaryContainer`/`onSurfaceVariant`. Adapt member names if the installed SDK differs; keep the styling.
- **Existing tests stay green:** a few screen tests assert the old combined subtitle string (e.g. `'bridge · local'`, `'X MB'`); update those to the new structure (individual chip/mono texts) while keeping the content assertions.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/ui/widgets/resource_widgets.dart        # LeadingAvatar + StatusPill + MonoText + MetaChip
app/lib/src/ui/containers_screen.dart               # card rows
app/lib/src/ui/profiles_screen.dart                 # card rows
app/lib/src/ui/images_screen.dart                   # card rows
app/lib/src/ui/networks_screen.dart                 # card rows
app/lib/src/ui/volumes_screen.dart                  # card rows
app/test/...                                          # widget tests for the shared widgets; screen tests stay green
```

---

## Task 1: Shared row widgets

**Files:**
- Create: `app/lib/src/ui/widgets/resource_widgets.dart`
- Test: `app/test/ui/widgets/resource_widgets_test.dart`

**Interfaces:**
- Produces:
  - `class LeadingAvatar extends StatelessWidget { const LeadingAvatar({required IconData icon, Color? background, Color? foreground}); }`
  - `class StatusPill extends StatelessWidget { const StatusPill({required String label, required Color color}); }`
  - `class MonoText extends StatelessWidget { const MonoText(String text, {TextStyle? style, int? maxLines, TextOverflow? overflow}); }`
  - `class MetaChip extends StatelessWidget { const MetaChip(String label, {IconData? icon}); }`

- [ ] **Step 1: Write the failing test**

Create `app/test/ui/widgets/resource_widgets_test.dart`:
```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:docker_mobile/src/ui/widgets/resource_widgets.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

void main() {
  testWidgets('LeadingAvatar renders its icon', (tester) async {
    await tester.pumpWidget(_host(const LeadingAvatar(icon: Icons.dns)));
    expect(find.byIcon(Icons.dns), findsOneWidget);
  });

  testWidgets('StatusPill shows its label', (tester) async {
    await tester.pumpWidget(_host(const StatusPill(label: 'running', color: Colors.green)));
    expect(find.text('running'), findsOneWidget);
  });

  testWidgets('MonoText renders text in a monospace font', (tester) async {
    await tester.pumpWidget(_host(const MonoText('nginx:latest')));
    final t = tester.widget<Text>(find.text('nginx:latest'));
    expect(t.style?.fontFamily, 'monospace');
  });

  testWidgets('MetaChip shows its label', (tester) async {
    await tester.pumpWidget(_host(const MetaChip('bridge')));
    expect(find.text('bridge'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/widgets/resource_widgets_test.dart`
Expected: FAIL — widgets undefined.

- [ ] **Step 3: Write the widgets**

Create `app/lib/src/ui/widgets/resource_widgets.dart`:
```dart
import 'package:flutter/material.dart';

/// A rounded, tinted icon container used as the leading element of list rows.
class LeadingAvatar extends StatelessWidget {
  final IconData icon;
  final Color? background;
  final Color? foreground;
  const LeadingAvatar({super.key, required this.icon, this.background, this.foreground});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: background ?? scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: foreground ?? scheme.onSecondaryContainer, size: 22),
    );
  }
}

/// A small filled pill with a status dot + label (e.g. container state).
class StatusPill extends StatelessWidget {
  final String label;
  final Color color;
  const StatusPill({super.key, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12)),
        ],
      ),
    );
  }
}

/// Monospace text for machine-ish strings (IDs, image refs, ports, paths).
class MonoText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  const MonoText(this.text, {super.key, this.style, this.maxLines, this.overflow});

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    return Text(text, style: base.copyWith(fontFamily: 'monospace'), maxLines: maxLines, overflow: overflow);
  }
}

/// A small tonal metadata tag (kind / driver / scope / size).
class MetaChip extends StatelessWidget {
  final String label;
  final IconData? icon;
  const MetaChip(this.label, {super.key, this.icon});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: scheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 12, color: scheme.onSurfaceVariant), const SizedBox(width: 4)],
          Text(label, style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run the test + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/widgets/resource_widgets_test.dart && flutter analyze`
Expected: PASS (4 tests); analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/ui/widgets/resource_widgets.dart app/test/ui/widgets/resource_widgets_test.dart
git commit -m "feat(app): LeadingAvatar + StatusPill + MonoText + MetaChip row widgets"
```

---

## Task 2: Containers + Connections card rows

**Files:**
- Modify: `app/lib/src/ui/containers_screen.dart`, `app/lib/src/ui/profiles_screen.dart`
- Test: existing `app/test/ui/*` for these screens stay green (update assertions if needed)

**Interfaces:**
- Consumes: `LeadingAvatar`/`StatusPill`/`MonoText`/`MetaChip` (Task 1), `StatusColors` (app_theme.dart).

- [ ] **Step 1: Redesign the Containers rows**

In `app/lib/src/ui/containers_screen.dart`, ensure imports include `import '../theme/app_theme.dart';` and add `import 'widgets/resource_widgets.dart';`. Replace the `itemBuilder`'s returned `ListTile(...)` with:
```dart
            final c = list[i];
            final name = c.names.isNotEmpty ? c.names.first : c.id;
            final sc = StatusColors.of(context);
            final color = c.state == 'running'
                ? sc.running
                : c.state == 'paused'
                    ? sc.paused
                    : sc.stopped;
            return Card(
              child: ListTile(
                isThreeLine: true,
                leading: LeadingAvatar(
                  icon: c.state == 'running' ? Icons.play_arrow_rounded : Icons.stop_rounded,
                  background: color.withValues(alpha: 0.18),
                  foreground: color,
                ),
                title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MonoText(c.image, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                    Text(c.status, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),
                trailing: StatusPill(label: c.state, color: color),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ContainerDetailScreen(containerId: c.id, containerName: name)),
                ),
              ),
            );
```
(Add `padding: const EdgeInsets.symmetric(vertical: 8)` to the `ListView.builder` for breathing room.)

- [ ] **Step 2: Redesign the Connections rows**

In `app/lib/src/ui/profiles_screen.dart`, add `import 'widgets/resource_widgets.dart';`. Replace the `for (final p in list) ListTile(...)` body with:
```dart
                  for (final p in list)
                    Card(
                      child: ListTile(
                        leading: LeadingAvatar(icon: _icon(p.kind)),
                        title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                        subtitle: Row(
                          children: [
                            MetaChip(p.kind.name),
                            const SizedBox(width: 8),
                            Expanded(child: MonoText(p.host, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall)),
                          ],
                        ),
                        onTap: () => launchConnection(context, ref, p),
                        trailing: PopupMenuButton<String>(
                          onSelected: (v) async {
                            if (v == 'edit') {
                              await Navigator.of(context).push(MaterialPageRoute(builder: (_) => ConnectionScreen(editing: p)));
                            } else if (v == 'delete') {
                              await ref.read(profileStoreProvider).delete(p.id);
                              ref.invalidate(profilesProvider);
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ),
                    ),
```

- [ ] **Step 3: Run the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; **all** app tests pass. If a profiles/containers test asserted the old combined subtitle (e.g. `find.text('ssh · 192.168.0.173')`), update it to assert the parts (`find.text('ssh')` via the chip + the host via `find.text('192.168.0.173')`); keep the name + navigation assertions. The `create_entrypoints_test` (FAB) and `home_screen_test` (nav) are unaffected.

- [ ] **Step 4: Commit**

```bash
git add app/lib/src/ui/containers_screen.dart app/lib/src/ui/profiles_screen.dart app/test/
git commit -m "feat(app): redesign Containers + Connections rows (cards, avatars, status pills, mono)"
```

---

## Task 3: Images + Networks + Volumes card rows

**Files:**
- Modify: `app/lib/src/ui/images_screen.dart`, `app/lib/src/ui/networks_screen.dart`, `app/lib/src/ui/volumes_screen.dart`
- Test: existing screen tests stay green (update assertions if needed)

**Interfaces:**
- Consumes: `LeadingAvatar`/`MonoText`/`MetaChip` (Task 1).

- [ ] **Step 1: Redesign the Images rows**

In `app/lib/src/ui/images_screen.dart`, add `import 'widgets/resource_widgets.dart';`. Replace the `itemBuilder`'s returned `ListTile(...)` with:
```dart
            final img = list[i];
            final name = _name(img.repoTags, img.id);
            final shortId = img.id.length > 19 ? img.id.substring(7, 19) : img.id;
            return Card(
              child: ListTile(
                leading: const LeadingAvatar(icon: Icons.layers),
                title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: MonoText(shortId, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                trailing: MetaChip('${(img.size / (1024 * 1024)).toStringAsFixed(1)} MB'),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => ImageDetailScreen(imageId: img.id, title: name)),
                ),
              ),
            );
```

- [ ] **Step 2: Redesign the Networks rows**

In `app/lib/src/ui/networks_screen.dart`, add `import 'widgets/resource_widgets.dart';`. Replace the `itemBuilder`'s returned `ListTile(...)` with:
```dart
            final n = list[i];
            return Card(
              child: ListTile(
                leading: const LeadingAvatar(icon: Icons.hub),
                title: Text(n.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [MetaChip(n.driver), const SizedBox(width: 8), MetaChip(n.scope)]),
                ),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => NetworkDetailScreen(networkId: n.id, title: n.name)),
                ),
              ),
            );
```

- [ ] **Step 3: Redesign the Volumes rows**

In `app/lib/src/ui/volumes_screen.dart`, add `import 'widgets/resource_widgets.dart';`. Replace the `itemBuilder`'s returned `ListTile(...)` with:
```dart
            final v = list[i];
            return Card(
              child: ListTile(
                leading: const LeadingAvatar(icon: Icons.storage),
                title: MonoText(v.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: MonoText(v.mountpoint, maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
                trailing: MetaChip(v.driver),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => VolumeDetailScreen(volumeName: v.name)),
                ),
              ),
            );
```

- [ ] **Step 4: Run the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; **all** app tests pass. Update any test asserting an old combined subtitle string: networks `'bridge · local'` → assert `find.text('bridge')` + `find.text('local')` (the two chips); images `'X MB'` size string is preserved in the `MetaChip` (still `find.text('178.7 MB')`); volumes `'driver · mountpoint'` → assert the driver chip + the mountpoint mono text. Keep the name + navigation assertions.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/ui/images_screen.dart app/lib/src/ui/networks_screen.dart app/lib/src/ui/volumes_screen.dart app/test/
git commit -m "feat(app): redesign Images + Networks + Volumes rows (cards, avatars, chips, mono)"
```

---

## Self-Review

**1. Spec coverage:**
- `LeadingAvatar` + `StatusPill` + `MonoText` + `MetaChip` → Task 1. ✓
- Containers + Connections card rows → Task 2. ✓
- Images + Networks + Volumes card rows → Task 3. ✓
- `StatusColors` for state colors; mono for technical strings; chips for metadata → Tasks 2/3. ✓
- Presentational only (no data/nav changes; onTap/menu preserved) → Tasks 2/3. ✓
- Out of scope (detail/dashboard/empty-states/charts) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete. The two SDK-name + test-update notes are bounded, explicit instructions, not placeholders.

**3. Type consistency:** `LeadingAvatar({icon, background?, foreground?})`, `StatusPill({label, color})`, `MonoText(text, {style?, maxLines?, overflow?})`, `MetaChip(label, {icon?})` (Task 1) are constructed identically in Tasks 2/3. `StatusColors.of(context)` + `.running/.paused/.stopped` (app_theme.dart, from Phase 3A) used in Task 2. `_icon(p.kind)` / `_name(...)` are the screens' existing helpers, reused. All `ListTile`/`Card`/`Navigator` usages are standard Flutter. ✓
