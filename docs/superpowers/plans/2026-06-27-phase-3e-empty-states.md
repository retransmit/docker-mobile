# Phase 3E — Designed Empty States — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reusable `EmptyState` widget wired into the empty branches of the list, Events, and Connections screens.

**Architecture:** Add `EmptyState` (centered tinted icon + title + optional message + optional action) to `resource_widgets.dart`; in each screen's `data:`/empty branch, render `EmptyState(...)` when the list is empty. Presentational only.

**Tech Stack:** Flutter 3.44 / Dart 3.12, `flutter_riverpod` (all existing).

## Global Constraints

- **Presentational only.** No data/provider/model change. Only the empty-list rendering changes; loading/error branches untouched; FABs/app-bar actions/refresh unchanged.
- `EmptyState({required IconData icon, required String title, String? message, Widget? action})` — centered icon-in-circle + title + optional message + optional action; omits message/action when null.
- **Wiring (exact copy):** Containers (`Icons.inventory_2`, "No containers", "This daemon has no containers yet."), Images (`Icons.layers`, "No images", "Pull an image to get started."), Networks (`Icons.hub`, "No networks"), Volumes (`Icons.storage`, "No volumes"), Events (`Icons.bolt`, "No events yet", "Events appear here as activity happens on the daemon."), Connections (`Icons.dns`, "No connections", "Add a Docker host to get started.", **action** = `FilledButton.icon` add → `ConnectionScreen`).
- **Flutter 3.44 APIs:** `scheme.secondaryContainer/onSecondaryContainer/onSurfaceVariant`. Adapt minimally if a member differs.
- **Existing tests stay meaningful:** update the Connections empty test (asserted "No saved connections — tap + to add one.") to the new `EmptyState`; keep non-empty + navigation tests green.
- **Toolchain:** Flutter at `C:\src\flutter`, NOT on PATH — prefix every flutter command with `export PATH="/c/src/flutter/bin:$PATH"` (Git Bash).
- **Discipline:** TDD, DRY, YAGNI, frequent commits; commit messages with NO `Co-Authored-By` trailer; feature branch.

---

## File Structure

```
app/lib/src/ui/widgets/resource_widgets.dart    # + EmptyState
app/lib/src/ui/{containers,images,networks,volumes,events,profiles}_screen.dart  # empty branches
app/test/ui/widgets/resource_widgets_test.dart  # + EmptyState test
app/test/ui/profiles_screen_test.dart           # updated empty assertion
```

---

## Task 1: EmptyState widget

**Files:**
- Modify: `app/lib/src/ui/widgets/resource_widgets.dart` (add `EmptyState`)
- Test: `app/test/ui/widgets/resource_widgets_test.dart`

**Interfaces:**
- Produces: `class EmptyState extends StatelessWidget { const EmptyState({required IconData icon, required String title, String? message, Widget? action}); }`.

- [ ] **Step 1: Write the failing test**

Append to `app/test/ui/widgets/resource_widgets_test.dart`:
```dart
  testWidgets('EmptyState shows icon + title + message + action', (tester) async {
    await tester.pumpWidget(_host(EmptyState(
      icon: Icons.dns,
      title: 'No connections',
      message: 'Add a Docker host to get started.',
      action: FilledButton(onPressed: () {}, child: const Text('Add connection')),
    )));
    expect(find.text('No connections'), findsOneWidget);
    expect(find.text('Add a Docker host to get started.'), findsOneWidget);
    expect(find.byIcon(Icons.dns), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add connection'), findsOneWidget);
  });

  testWidgets('EmptyState omits message and action when null', (tester) async {
    await tester.pumpWidget(_host(const EmptyState(icon: Icons.hub, title: 'No networks')));
    expect(find.text('No networks'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/widgets/resource_widgets_test.dart`
Expected: FAIL — `EmptyState` undefined.

- [ ] **Step 3: Implement EmptyState**

Append to `app/lib/src/ui/widgets/resource_widgets.dart`:
```dart
/// A centered empty-state placeholder: tinted icon + title + optional message + optional action.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(color: scheme.secondaryContainer, shape: BoxShape.circle),
              child: Icon(icon, size: 36, color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: 16),
            Text(title, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            if (message != null) ...[
              const SizedBox(height: 6),
              Text(message!, textAlign: TextAlign.center, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
            ],
            if (action != null) ...[
              const SizedBox(height: 20),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run the test + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter test test/ui/widgets/resource_widgets_test.dart && flutter analyze`
Expected: PASS; analyzer clean.

- [ ] **Step 5: Commit**

```bash
git add app/lib/src/ui/widgets/resource_widgets.dart app/test/ui/widgets/resource_widgets_test.dart
git commit -m "feat(app): EmptyState placeholder widget"
```

---

## Task 2: Wire EmptyState into the screens

**Files:**
- Modify: `app/lib/src/ui/containers_screen.dart`, `images_screen.dart`, `networks_screen.dart`, `volumes_screen.dart`, `events_screen.dart`, `profiles_screen.dart`
- Test: `app/test/ui/profiles_screen_test.dart` (+ optional events/list empty assertions)

**Interfaces:**
- Consumes: `EmptyState` (Task 1).

- [ ] **Step 1: Wire the four list screens**

In each of `containers_screen.dart`, `images_screen.dart`, `networks_screen.dart`, `volumes_screen.dart`: add `import 'widgets/resource_widgets.dart';` (already present in `containers_screen.dart` from 3B; add to the other three). Then change each screen's `data: (list) => ListView.builder( ... )` to guard on empty:
- **containers_screen.dart:** `data: (list) => list.isEmpty ? const EmptyState(icon: Icons.inventory_2, title: 'No containers', message: 'This daemon has no containers yet.') : ListView.builder( ...existing... ),`
- **images_screen.dart:** `data: (list) => list.isEmpty ? const EmptyState(icon: Icons.layers, title: 'No images', message: 'Pull an image to get started.') : ListView.builder( ...existing... ),`
- **networks_screen.dart:** `data: (list) => list.isEmpty ? const EmptyState(icon: Icons.hub, title: 'No networks') : ListView.builder( ...existing... ),`
- **volumes_screen.dart:** `data: (list) => list.isEmpty ? const EmptyState(icon: Icons.storage, title: 'No volumes') : ListView.builder( ...existing... ),`

(Wrap the existing `ListView.builder(...)` unchanged as the `:` branch — do not alter the builder body.)

- [ ] **Step 2: Wire the Events screen**

In `app/lib/src/ui/events_screen.dart` add `import 'widgets/resource_widgets.dart';`, and replace the empty branch `? const Center(child: Text('No events yet.'))` with:
```dart
                    ? const EmptyState(
                        icon: Icons.bolt,
                        title: 'No events yet',
                        message: 'Events appear here as activity happens on the daemon.',
                      )
```
(Keep the `state.status == EventsStatus.error ? Center(...) :` branch and the filter chips unchanged.)

- [ ] **Step 3: Wire the Connections screen**

In `app/lib/src/ui/profiles_screen.dart` add `import 'widgets/resource_widgets.dart';`, and replace the empty branch `? const Center(child: Text('No saved connections — tap + to add one.'))` with:
```dart
            ? EmptyState(
                icon: Icons.dns,
                title: 'No connections',
                message: 'Add a Docker host to get started.',
                action: FilledButton.icon(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ConnectionScreen())),
                  icon: const Icon(Icons.add),
                  label: const Text('Add connection'),
                ),
              )
```
(`ConnectionScreen` is already imported in this file.)

- [ ] **Step 4: Update the Connections empty test**

In `app/test/ui/profiles_screen_test.dart`, find the test asserting the old empty text (`'No saved connections — tap + to add one.'`) and update it to the new structure:
```dart
    expect(find.text('No connections'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Add connection'), findsOneWidget);
```
(Keep the rest of that test — the empty-profiles fixture/override — unchanged. If no such empty test exists, add a minimal one using the file's existing in-memory profile-store override with an empty list.)

- [ ] **Step 5: Run the full suite + analyzer**

Run: `export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter analyze && flutter test`
Expected: analyzer clean; all tests pass (the Connections empty state now shows `EmptyState` + Add button; the non-empty list/navigation tests still pass; the other screens compile + their existing tests stay green).

- [ ] **Step 6: Commit**

```bash
git add app/lib/src/ui/containers_screen.dart app/lib/src/ui/images_screen.dart app/lib/src/ui/networks_screen.dart app/lib/src/ui/volumes_screen.dart app/lib/src/ui/events_screen.dart app/lib/src/ui/profiles_screen.dart app/test/ui/profiles_screen_test.dart
git commit -m "feat(app): designed empty states across list/Events/Connections screens"
```

---

## Self-Review

**1. Spec coverage:**
- `EmptyState` widget → Task 1. ✓
- Containers/Images/Networks/Volumes empty branches → Task 2 Step 1. ✓
- Events empty → Task 2 Step 2. ✓
- Connections empty + Add action → Task 2 Step 3. ✓
- Presentational only (loading/error/providers/FABs unchanged) → Task 2 wraps only the empty branch. ✓
- Out of scope (charts) → absent. ✓

**2. Placeholder scan:** No TBD/"handle errors"/"similar to". Every code/command step is complete; the "wrap the existing builder unchanged" instruction is explicit and mechanical, not a placeholder.

**3. Type consistency:** `EmptyState({icon, title, message?, action?})` (Task 1) constructed identically across all six screens (Task 2). `ConnectionScreen` is the existing route. `EventsStatus`/`state.visibleEvents` are events_screen's existing types. ✓
