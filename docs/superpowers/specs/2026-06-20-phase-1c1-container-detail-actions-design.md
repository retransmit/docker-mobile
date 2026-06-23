# docker-mobile Phase 1C-1 — Container Detail & Lifecycle Actions — Design Spec

**Date:** 2026-06-20
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 0 + 1A + 1B (on `main`). First slice of sub-project C (resource breadth). C decomposes into C1 containers, C2 images, C3 networks/volumes, C4 system.

---

## 1. Summary

C1 completes the container story: a **container detail screen** (the navigation hub for each container) showing inspect data, plus **lifecycle write actions** (start/stop/restart/pause/unpause/kill/remove/rename). Tapping a container row now opens the detail screen; **Logs** and **Exec** become buttons inside it.

## 2. Goals / Non-goals

**Goals**
- `Transport.delete`; a rich `ContainerDetail` model; `DockerApiClient` inspect-detail + lifecycle action methods.
- `ContainerDetailScreen` hub with overview + state-aware action buttons + Logs/Exec entry + confirm dialogs for destructive actions.
- Navigation refactor: container row tap → detail (remove the row's trailing exec icon).

**Non-goals (this slice)**
- Container **create/run** (large config surface) — its own later slice.
- Images / networks / volumes / system — C2/C3/C4.
- Editing container resources (`update`), `top`/`stats`/`diff`/`cp`/`export` — later slices.

## 3. Scope decisions (locked)

- **Navigation:** detail-as-hub. Row tap → `ContainerDetailScreen`; Logs/Exec are buttons there; the row's trailing exec icon is removed.
- **Actions in C1:** start, stop, restart, pause, unpause, kill, rename, remove (with force + remove-volumes options). Destructive (remove, kill) require confirmation.
- **Status handling:** `204` success; `304` (already started/stopped) treated as a successful no-op; `409` (e.g. remove running without force) surfaced clearly; other non-2xx → `DockerApiException`.
- **Model:** new `ContainerDetail` for the detail screen; the existing minimal `ContainerInspect` continues to serve the logs path (`tty`).

## 4. Components

### 4.1 Transport (app)
- `Transport.delete(String path, {Map<String,String>? query}) → Future<http.Response>`; `AgentTransport` implements via HTTP DELETE + bearer header. Existing `Transport` fakes get a stub.

### 4.2 Model (app) — `lib/src/api/models/container_detail.dart`
- `ContainerDetail`:
  - `String id, name, image, command, created`
  - `ContainerStateInfo state` = `{ String status; bool running; bool paused; int? exitCode; String? startedAt; }`
  - `List<PortMapping> ports` = `{ String? ip; int? privatePort; int? publicPort; String type; }`
  - `List<MountInfo> mounts` = `{ String source; String destination; String mode; bool rw; }`
  - `List<String> env`
  - `String restartPolicy`
  - `List<String> networks`
  - `factory ContainerDetail.fromJson(Map)` reading `Id`, `Name` (strip `/`), `Config.{Image,Cmd,Env}`, `Created`, `State.{Status,Running,Paused,ExitCode,StartedAt}`, `NetworkSettings.Ports` (or top-level `Ports`), `Mounts`, `HostConfig.RestartPolicy.Name`, `NetworkSettings.Networks` (keys).

### 4.3 DockerApiClient (app) — additions
- `Future<ContainerDetail> inspectContainerDetail(String id)` — GET `/containers/{id}/json`.
- `Future<void> startContainer(String id)` — POST `/containers/{id}/start` (204/304 ok).
- `Future<void> stopContainer(String id)` — POST `/containers/{id}/stop` (204/304 ok).
- `Future<void> restartContainer(String id)` — POST `/containers/{id}/restart` (204 ok).
- `Future<void> pauseContainer(String id)` — POST `/containers/{id}/pause` (204 ok).
- `Future<void> unpauseContainer(String id)` — POST `/containers/{id}/unpause` (204 ok).
- `Future<void> killContainer(String id)` — POST `/containers/{id}/kill` (204 ok).
- `Future<void> renameContainer(String id, String newName)` — POST `/containers/{id}/rename?name=` (204 ok).
- `Future<void> removeContainer(String id, {bool force = false, bool removeVolumes = false})` — DELETE `/containers/{id}?force=&v=` (204 ok).
- Each throws `DockerApiException` on a non-success status (with `304` accepted only for start/stop).

### 4.4 State (app)
- `containerDetailProvider = FutureProvider.family<ContainerDetail, String>` → `inspectContainerDetail`.
- After a successful action the UI calls `ref.invalidate(containerDetailProvider(id))` and `ref.invalidate(containersProvider)`.

### 4.5 UI (app)
- `ContainerDetailScreen(containerId, containerName)` — `ConsumerWidget` watching `containerDetailProvider(id)`:
  - Overview: state badge (running/paused/exited + exit code), image, command, created, ports, mounts, env (collapsible), restart policy, networks.
  - Actions row/menu — **state-aware**: start (when not running), stop + restart + pause + kill (when running), unpause (when paused), rename, remove (always). Destructive (remove, kill) → `AlertDialog` confirm; remove dialog has **force** + **remove volumes** switches; rename → text-field dialog.
  - Buttons: **Logs** → `LogsScreen`, **Exec** → `ExecScreen`.
  - Each action runs the client call, shows a `SnackBar` (success or error), and refreshes.
- `ContainersScreen` — row tap → `ContainerDetailScreen`; remove the trailing exec icon.

## 5. Data flow & error handling
- Tap container → `ContainerDetailScreen` → `containerDetailProvider(id)` → render (loading/error/data).
- Action → confirm (destructive) → `client.<action>(id)` → success: invalidate detail+list + success snackbar; `DockerApiException` → error snackbar with the message; `304` → success no-op; `409` (remove running w/o force) → snackbar suggesting force.
- A `404` on detail (container removed) → error state with a back affordance.

## 6. File structure
```
app/lib/src/transport/transport.dart          # + delete
app/lib/src/transport/agent_transport.dart     # + delete
app/lib/src/api/models/container_detail.dart    # ContainerDetail + nested types
app/lib/src/api/docker_api_client.dart          # + inspectContainerDetail + 8 action methods
app/lib/src/state/providers.dart                # + containerDetailProvider
app/lib/src/ui/container_detail_screen.dart     # ContainerDetailScreen
app/lib/src/ui/containers_screen.dart           # tap -> detail; drop exec icon
app/test/...                                     # mirrors the above
# + delete() stub added to existing Transport fakes
```

## 7. Testing
- `Transport.delete` — MockClient asserts DELETE + bearer + query.
- `ContainerDetail.fromJson` — parses state/ports/mounts/env/networks/restart policy; tolerates missing fields.
- `DockerApiClient` actions — fake transport asserts method/path/query per action and status handling: `startContainer` succeeds on 204 AND 304; `stopContainer` same; `removeContainer(force:true, removeVolumes:true)` → `DELETE /containers/{id}?force=true&v=true`; `renameContainer` → `POST /containers/{id}/rename?name=new`; a 409 → `DockerApiException`.
- `containerDetailProvider` — via a fake client/transport.
- `ContainerDetailScreen` widget test — override providers: renders state/image/ports; tapping **Start** calls `startContainer` (fake) and shows a snackbar; **Remove** opens the confirm dialog; action buttons reflect running vs stopped state.

## 8. Dependencies
None new (reuses http/riverpod).

## 9. Open questions / to confirm during planning
- Exact port/mount JSON shapes across Engine API versions (parse defensively; tolerate absent `Ports`/`Mounts`).
- Whether `stopContainer` exposes a timeout in C1 (default: no `t` param; add later).
- Snackbar vs inline status for long actions (default: snackbar + provider refresh).
