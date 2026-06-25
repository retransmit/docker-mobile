# docker-mobile Phase 1C-4 — System Dashboard — Design Spec

**Date:** 2026-06-25
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 0/1A/1B/1C-1/1C-2/1C-3a/1C-3b (on `main`). Final slice of sub-project C. Completes the resource-breadth surface.

---

## 1. Summary

C4 adds a **System** dashboard tab: daemon info/version, a disk-usage breakdown (`/system/df`), and a **System prune** action that orchestrates the per-resource prunes client-side (Docker has no single system-prune endpoint), mirroring `docker system prune [-a] [--volumes]`.

## 2. Goals / Non-goals

**Goals**
- Models `SystemInfo`, `VersionInfo`, `DiskUsage`.
- `DockerApiClient`: `getInfo`, `getVersion`, `getDiskUsage`, `pruneContainers`, `pruneBuildCache`, and a `systemPrune({allImages, includeVolumes})` orchestrator.
- `systemDashboardProvider` + `SystemScreen`; a **System** tab on `HomeScreen`.

**Non-goals (this slice)**
- Editing/writing daemon config (`daemon.json` is not API-writable — agent/SSH only; out of scope).
- Live events stream / stats charts (later; reuse the streaming foundation).
- Container create/run; the D transports.

## 3. Scope decisions (locked)

- **System prune:** orchestrated as `pruneContainers(); pruneNetworks(); pruneImages(danglingOnly: !allImages); pruneBuildCache(); if (includeVolumes) pruneVolumes();`. Confirm dialog offers **all images** (`-a`) and **also volumes** (`--volumes`) toggles.
- **Status codes:** all reads = `200`; `pruneContainers`/`pruneBuildCache` = `200`; non-success → `DockerApiException`.
- **Nav:** add a System tab (icon `Icons.monitor_heart`); now Containers | Images | Networks | Volumes | System (5 tabs, Material's max).
- **Provider:** one `systemDashboardProvider` fetching info+version+df in parallel (`Future.wait`) for a single loading/error state.
- **Dialog/controller discipline:** the prune confirm dialog uses a `StatefulWidget`/`StatefulBuilder` for its toggle state (no leaked controllers; carried from prior slices). Async-gap discipline (capture messenger/navigator before await; `mounted`-guarded post-await `setState`).

## 4. Architecture

```
HomeScreen bottom nav: Containers | Images | Networks | Volumes | System(new)
  SystemScreen (dashboard)
    Daemon: version/api/os-arch/kernel/cpu/mem/storage-driver  (GET /info, GET /version)
    Containers summary + images count                          (GET /info)
    Disk usage: images/containers/volumes/build-cache sizes    (GET /system/df)
    [System prune] -> confirm(all-images?, also-volumes?) -> orchestrated prunes -> refresh
```

## 5. Components

### 5.1 Models — `lib/src/api/models/system_info.dart`
- `SystemInfo` (from `GET /info`): `serverVersion`, `os`, `osType`, `architecture`, `kernelVersion`, `int ncpu`, `int memTotal`, `String storageDriver`, `int containers`, `containersRunning`, `containersPaused`, `containersStopped`, `int images`. Reads `ServerVersion`, `OperatingSystem`, `OSType`, `Architecture`, `KernelVersion`, `NCPU`, `MemTotal`, `Driver`, `Containers`, `ContainersRunning`, `ContainersPaused`, `ContainersStopped`, `Images`.
- `VersionInfo` (from `GET /version`): `version`, `apiVersion`, `goVersion`, `os`, `arch`. Reads `Version`, `ApiVersion`, `GoVersion`, `Os`, `Arch`.
- `DiskUsageCategory { String name; int count; int size; }` and `DiskUsage` (from `GET /system/df`): `images`, `containers`, `volumes`, `buildCache` (each a `DiskUsageCategory`), computed by summing the df arrays — images `count=Images.length, size=sum(Images[].Size)`; containers `count=Containers.length, size=sum(Containers[].SizeRw ?? 0)`; volumes `count=Volumes.length, size=sum(Volumes[].UsageData.Size ?? 0)`; build cache `count=BuildCache.length, size=sum(BuildCache[].Size ?? 0)`. `int total` getter sums the four.

### 5.2 DockerApiClient — additions
- `Future<SystemInfo> getInfo()` — GET `/info` (200).
- `Future<VersionInfo> getVersion()` — GET `/version` (200).
- `Future<DiskUsage> getDiskUsage()` — GET `/system/df` (200).
- `Future<void> pruneContainers()` — POST `/containers/prune` (200).
- `Future<void> pruneBuildCache()` — POST `/build/prune` (200).
- `Future<void> systemPrune({bool allImages = false, bool includeVolumes = false})` — awaits, in order: `pruneContainers()`, `pruneNetworks()`, `pruneImages(danglingOnly: !allImages)`, `pruneBuildCache()`, and (if `includeVolumes`) `pruneVolumes()`.

### 5.3 State
- `systemDashboardProvider = FutureProvider<({SystemInfo info, VersionInfo version, DiskUsage df})>` → `Future.wait([getInfo, getVersion, getDiskUsage])`.

### 5.4 UI
- `SystemScreen` (`ConsumerWidget`) watching `systemDashboardProvider`:
  - **Daemon** card: server version, API version, `os/arch`, kernel, `NCPU` CPUs, memory (human MB/GB), storage driver.
  - **Containers** card: total · running · paused · stopped; images count.
  - **Disk usage** card: per-category human size (images, containers, volumes, build cache) + total.
  - app-bar/refresh; a **System prune** button → confirm dialog (`StatefulBuilder`) with **all images** + **also volumes** switches → `systemPrune(...)` → on success invalidate `systemDashboardProvider` (+ the resource list providers `containersProvider`/`imagesProvider`/`networksProvider`/`volumesProvider`) + "Pruned" snackbar; error → snackbar.
- `HomeScreen` — add a System `NavigationDestination` (`Icons.monitor_heart`) + `SystemScreen()` in the `IndexedStack`.

## 6. Data flow & error handling
- `systemDashboardProvider` loads the three GETs in parallel; any failure → error state; refresh invalidates it.
- System prune runs the sequence (stops at the first failing prune → `DockerApiException` → error snackbar); success → invalidate the dashboard + resource lists + "Pruned" snackbar.
- The prune confirm dialog captures messenger/navigator before the await; the screen is a `ConsumerWidget` (no `setState`), so no use-after-dispose.

## 7. File structure
```
app/lib/src/api/models/system_info.dart          # SystemInfo + VersionInfo + DiskUsage(+Category)
app/lib/src/api/docker_api_client.dart            # + getInfo/getVersion/getDiskUsage/pruneContainers/pruneBuildCache/systemPrune
app/lib/src/state/providers.dart                  # + systemDashboardProvider
app/lib/src/ui/system_screen.dart                 # SystemScreen
app/lib/src/ui/home_screen.dart                   # + System tab
app/test/...                                        # mirrors the above
```

## 8. Testing
- Models: `SystemInfo`/`VersionInfo` parse fields; `DiskUsage` sums the df arrays into per-category totals (and tolerates missing arrays).
- Client: `getInfo`/`getVersion`/`getDiskUsage` routes + parse; `pruneContainers`→`/containers/prune`, `pruneBuildCache`→`/build/prune`; `systemPrune(allImages:true, includeVolumes:true)` issues the expected sequence (assert recorded calls: `/containers/prune`, `/networks/prune`, `/images/prune` with `dangling:["false"]`, `/build/prune`, `/volumes/prune`); `systemPrune()` defaults omit `/volumes/prune` and use `dangling:["true"]`.
- Widgets: `SystemScreen` (renders daemon + disk sections from a fake dashboard; the System-prune confirm dialog with both toggles on → drives `systemPrune` and the underlying prune calls), `HomeScreen` (System destination present, selecting it sets index 4).

## 9. Dependencies
None new.

## 10. Open questions / to confirm during planning
- Human size formatting (bytes → MB/GB): a small local helper (`_humanSize`); confirm thresholds during plan.
- `pruneBuildCache` body/params: send no body (prune all reclaimable build cache); confirm against the daemon's `/build/prune` defaults.
- Whether `systemPrune` should surface per-step reclaimed bytes; default: a simple success/"Pruned" message this slice.
