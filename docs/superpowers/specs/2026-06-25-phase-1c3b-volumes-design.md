# docker-mobile Phase 1C-3b — Volumes — Design Spec

**Date:** 2026-06-25
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 0/1A/1B/1C-1/1C-2/1C-3a (on `main`). Second half of C3 (networks done in C3a). Reuses the `KeyValueEditor` widget from C3a.

---

## 1. Summary

C3b adds volume management: a **Volumes** bottom-nav tab with list, detail (driver/mountpoint/scope/labels/options), create (name + driver + labels + driver-options), remove (with force), and prune. It mirrors the networks slice, reusing `KeyValueEditor`, and is simpler (no IPAM).

## 2. Goals / Non-goals

**Goals**
- `DockerVolume` model (one shape for list + inspect).
- `DockerApiClient`: listVolumes, inspectVolume, createVolume, removeVolume, pruneVolumes.
- `VolumesScreen`, `VolumeDetailScreen`, `VolumeCreateSheet`; a **Volumes** tab on `HomeScreen`.

**Non-goals (this slice)**
- System (C4); container create/run.
- Volume usage/size (`UsageData`) — defer (requires `?dangling`/df cross-ref).

## 3. Scope decisions (locked)

- **Identity:** volumes are keyed by **Name** (no hash id); detail/remove use the name.
- **Create:** name + driver (default `local`) + Labels (`KeyValueEditor`) + DriverOpts (`KeyValueEditor`); omit empty Labels/DriverOpts from the body.
- **Status codes:** create = `201`; remove = `204`; prune = `200`; list/inspect = `200`; non-success → `DockerApiException` (a `409` volume-in-use on remove surfaced as such).
- **Nav:** add a Volumes tab (icon `Icons.storage`); now Containers | Images | Networks | Volumes (4 tabs).
- **Async + controller discipline:** capture messenger/navigator before await, `mounted`-guard post-await `setState`, `StatefulWidget` dialogs that dispose controllers in `State.dispose` (carried from C3a).

## 4. Architecture

```
HomeScreen bottom nav: Containers | Images | Networks | Volumes(new)
  VolumesScreen (list) --app-bar--> Create -> VolumeCreateSheet ; Prune (confirm) ; refresh
       │ tap
       ▼
  VolumeDetailScreen (driver/mountpoint/created/scope/labels/options) --Remove(confirm + force)-->
```

## 5. Components

### 5.1 Model — `lib/src/api/models/docker_volume.dart`
- `DockerVolume`: `name`, `driver`, `mountpoint`, `createdAt`, `scope`, `Map<String,String> labels`, `Map<String,String> options`. `factory DockerVolume.fromJson(Map)` reading `Name`, `Driver`, `Mountpoint`, `CreatedAt`, `Scope`, `Labels`, `Options` (values coerced to string; null-tolerant).

### 5.2 DockerApiClient — additions
- `Future<List<DockerVolume>> listVolumes()` — GET `/volumes` → `(json['Volumes'] as List? ?? [])` (200).
- `Future<DockerVolume> inspectVolume(String name)` — GET `/volumes/{name}` (200).
- `Future<DockerVolume> createVolume({required String name, String driver = 'local', Map<String,String> labels = const {}, Map<String,String> driverOpts = const {}})` — POST `/volumes/create` body `{Name, Driver}` (+ `Labels`/`DriverOpts` only when non-empty) (201) → `DockerVolume.fromJson`.
- `Future<void> removeVolume(String name, {bool force = false})` — DELETE `/volumes/{name}?force=` (204).
- `Future<void> pruneVolumes()` — POST `/volumes/prune` (200).

### 5.3 State
- `volumesProvider = FutureProvider<List<DockerVolume>>`; `volumeDetailProvider = FutureProvider.family<DockerVolume, String>`.

### 5.4 UI
- `VolumesScreen` — list (`name` · `driver`; mountpoint as subtitle); app-bar **Create** (push `VolumeCreateSheet`), **Prune** (confirm), refresh; tap → `VolumeDetailScreen`.
- `VolumeDetailScreen` — driver, mountpoint, created, scope, labels, options; **Remove** (confirm dialog with a **force** switch). Success → invalidate `volumesProvider` + pop + snackbar; `409` → error snackbar.
- `VolumeCreateSheet` (StatefulWidget) — name field; driver field (default `local`); `KeyValueEditor` for Labels and for DriverOpts; a **Create** button disabled until a non-empty trimmed name; `_busy` gates double-submit. On create → `createVolume(...)` → invalidate `volumesProvider`, pop, success snackbar; error → `mounted`-guarded `setState` + snackbar.
- `HomeScreen` — add a Volumes `NavigationDestination` (`Icons.storage`) + `VolumesScreen()` in the `IndexedStack`.

## 6. Data flow & error handling
- List/detail via providers. Create/remove/prune → client → on success invalidate `volumesProvider` (+ `volumeDetailProvider` for the name) + success snackbar; `DockerApiException` → error snackbar (`409` in-use verbatim).
- Create validates a non-empty trimmed name client-side.
- All controllers disposed on sheet dispose; post-await `setState` is `mounted`-guarded.

## 7. File structure
```
app/lib/src/api/models/docker_volume.dart        # DockerVolume
app/lib/src/api/docker_api_client.dart            # + 5 volume methods
app/lib/src/state/providers.dart                  # + volumes providers
app/lib/src/ui/volume_create_sheet.dart           # VolumeCreateSheet
app/lib/src/ui/volume_detail_screen.dart          # VolumeDetailScreen
app/lib/src/ui/volumes_screen.dart                # VolumesScreen
app/lib/src/ui/home_screen.dart                   # + Volumes tab
app/test/...                                        # mirrors the above
```

## 8. Testing
- `DockerVolume.fromJson` parses name/driver/mountpoint/scope/labels/options; tolerates missing fields.
- Client: `createVolume` asserts the body (Name, Driver; Labels/DriverOpts omitted when empty, included when present); `removeVolume(force:true)` → `DELETE /volumes/{name}?force=true` 204; `pruneVolumes` → `POST /volumes/prune` 200; `listVolumes` parses `{Volumes:[…]}`; a `409` on remove → `DockerApiException`.
- Widgets: `VolumeCreateSheet` (enter name + a label → Create → assert client body; Create disabled without a name; a failing create → error snackbar, no crash), `VolumeDetailScreen` (render + remove-confirm drives `removeVolume` + pops), `VolumesScreen` (list + prune confirm → `pruneVolumes`), `HomeScreen` (Volumes destination present, selecting it sets index 3).

## 9. Dependencies
None new (reuses `KeyValueEditor`).

## 10. Open questions / to confirm during planning
- `createVolume` return: parse the created volume (the daemon returns the full object) vs just the name; parse the full `DockerVolume` for consistency.
- `CreatedAt` display: keep the raw RFC3339 string for this slice.
- Volume `UsageData` (size/refcount): out of scope here; a later enhancement may add `?dangling`/df cross-referencing.
