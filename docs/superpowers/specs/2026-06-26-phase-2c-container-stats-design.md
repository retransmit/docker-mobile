# docker-mobile Phase 2C — Live Container Stats — Design Spec

**Date:** 2026-06-26
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** All of Milestone 1 + Phase 2A/2B (on `main`). First half of the "live events + stats" work (item #2); the daemon **events feed** is a separate follow-up slice.

---

## 1. Summary

Phase 2C adds a **live per-container stats** screen — CPU% and memory% sparkline charts (fl_chart) plus live network and block-I/O numbers — streamed from `GET /containers/{id}/stats?stream=true`, reached via a **Stats** button on the container detail screen. It reuses the existing streaming foundation.

## 2. Goals / Non-goals

**Goals**
- `ContainerStats` — a pure model computing CPU%, memory used/limit/%, network RX/TX, and block read/write from one streamed stats object.
- `DockerApiClient.streamContainerStats(id) → Stream<ContainerStats>` (NDJSON byte-buffered, like `pullImage`).
- `StatsNotifier` — holds the latest sample + rolling CPU%/mem% windows for the charts.
- `ContainerStatsScreen` — two fl_chart `LineChart` sparklines + live number rows; loading/error states.
- A **Stats** button on `ContainerDetailScreen`; `fl_chart` dependency.

**Non-goals (this slice)**
- The daemon **events feed** (separate slice).
- Per-process stats, historical persistence, pause/zoom on the chart, multi-container dashboards, configurable window.
- Stats for stopped containers (the stream simply yields nothing / errors; shown as the error/empty state).

## 3. Scope decisions (locked)

- **Charts:** `fl_chart` `LineChart` sparklines for CPU% and memory% over a rolling window (`kStatsWindow = 60` samples ≈ 1 min at 1/s).
- **Metrics:** CPU% + memory (used/limit/%) as numbers + sparklines; network RX/TX and block read/write as live numbers.
- **CPU% formula:** `(cpu_delta / system_delta) × online_cpus × 100`, guarded `system_delta > 0 && cpu_delta > 0` (each streamed object carries `precpu_stats`, so it is self-contained).
- **Memory:** `used = usage − cache` (cache = `stats.cache` ?? `stats.inactive_file` ?? 0, clamped ≥ 0); percent = `used/limit`.
- **Entry point:** a Stats button on `ContainerDetailScreen` (next to Logs/Exec) → pushed `ContainerStatsScreen`.
- **Lifecycle:** the screen owns the `StatsNotifier`; the stats stream is canceled on dispose (the transport channel closes — works over agent/TLS/SSH).
- **Robustness:** `fromJson` tolerates missing `cpu_stats`/`memory_stats`/`networks`/`blkio_stats` (→ 0); malformed NDJSON lines are skipped.

## 4. Architecture

```
ContainerDetailScreen -- [Stats] --> ContainerStatsScreen(containerId, containerName)

ContainerStatsScreen (ConsumerStatefulWidget)
  initState: notifier = StatsNotifier(client, id)   ; ListenableBuilder(notifier)
  dispose:   notifier.dispose()  -> cancels the stream (closes the channel)

StatsNotifier (ChangeNotifier)             [lib/src/state/stats_notifier.dart]
  client.streamContainerStats(id).listen -> latest + cpuHistory/memHistory (capped kStatsWindow) + status
  status: loading | streaming | error

DockerApiClient.streamContainerStats(id)   -> transport.stream('/containers/{id}/stats', {stream:'true'})
  NDJSON byte-buffer -> ContainerStats.fromJson per line

ContainerStats.fromJson (pure)             [lib/src/api/models/container_stats.dart]
  cpuPercent, memoryUsed, memoryLimit, memoryPercent, netRx, netTx, blockRead, blockWrite
```

## 5. Components

### 5.1 Model — `lib/src/api/models/container_stats.dart`
- `class ContainerStats { final double cpuPercent; final int memoryUsed, memoryLimit; final double memoryPercent; final int netRx, netTx, blockRead, blockWrite; const ContainerStats({...}); factory ContainerStats.fromJson(Map<String,dynamic>); }`
- CPU%: read `cpu_stats.cpu_usage.total_usage`/`system_cpu_usage`/`online_cpus` (fallback to `cpu_usage.percpu_usage.length`, then 1) and the `precpu_stats` equivalents; `cpuDelta = total − preTotal`, `sysDelta = system − preSystem`; `cpuPercent = (sysDelta > 0 && cpuDelta > 0) ? cpuDelta/sysDelta × online × 100 : 0`.
- Memory: `usage − cache` (clamped ≥ 0), `limit`, percent (0 if limit ≤ 0).
- Network: sum `rx_bytes`/`tx_bytes` over `networks.*`.
- Block I/O: sum `value` over `blkio_stats.io_service_bytes_recursive` entries by `op` (`Read`/`Write`, case-insensitive).

### 5.2 DockerApiClient — addition
- `Stream<ContainerStats> streamContainerStats(String id)` — `transport.stream('/containers/$id/stats', query: {'stream': 'true'})`; byte-buffer to newline boundaries; `jsonDecode` each line → `ContainerStats.fromJson`; skip lines that fail to parse. (Same NDJSON pattern as `pullImage`.)

### 5.3 State — `lib/src/state/stats_notifier.dart`
- `const int kStatsWindow = 60;`
- `enum StatsStatus { loading, streaming, error }`
- `class StatsNotifier extends ChangeNotifier`: fields `ContainerStats? latest; final List<double> cpuHistory = []; final List<double> memHistory = []; StatsStatus status = StatsStatus.loading; String? error;`. Constructor `StatsNotifier(DockerApiClient client, String id)` subscribes; on each sample → set `latest`, append `cpuPercent`/`memoryPercent` (trim to `kStatsWindow`), `status = streaming`, `notifyListeners()`; on error → `error` + `status = error`; `dispose()` cancels the subscription.

### 5.4 UI — `lib/src/ui/container_stats_screen.dart`
- `ContainerStatsScreen` (`ConsumerStatefulWidget`, `{required String containerId, required String containerName}`): builds a `StatsNotifier` in `initState` (client from `dockerClientProvider`), `ListenableBuilder` on it.
  - `loading` → centered spinner ("Waiting for stats…").
  - `error` → error text.
  - `streaming` → a `Column`/`ListView`: a **CPU%** `LineChart` sparkline (minY 0, maxY 100, no axes/grid/dots) over `cpuHistory` + the current `cpuPercent` label; a **Memory%** sparkline over `memHistory` + `used / limit` (human bytes) label; number rows for **Network** ↓RX/↑TX and **Block I/O** read/write (human bytes). A small local `_humanBytes` helper.
- `pubspec.yaml` gains `fl_chart`.

### 5.5 Entry point — `ContainerDetailScreen`
- Add a **Stats** button (mirroring the Logs button) → `Navigator.push(ContainerStatsScreen(containerId: id, containerName: name))`.

## 6. Data flow & error handling
- Stream: `transport.stream` → NDJSON lines → `ContainerStats` → notifier → UI. Cancel on dispose closes the channel.
- A stopped container / immediate stream end → stays on loading or transitions via `onDone`; a transport error → error status. Malformed lines are skipped (no crash).
- No secrets; read-only.

## 7. File structure
```
app/lib/src/api/models/container_stats.dart       # ContainerStats + fromJson
app/lib/src/api/docker_api_client.dart            # + streamContainerStats
app/lib/src/state/stats_notifier.dart             # StatsNotifier + kStatsWindow + StatsStatus
app/lib/src/ui/container_stats_screen.dart        # ContainerStatsScreen (fl_chart)
app/lib/src/ui/container_detail_screen.dart       # + Stats button
app/pubspec.yaml                                   # + fl_chart
app/test/...                                        # mirrors the above
```

## 8. Testing
- `ContainerStats.fromJson`: CPU% from a known `cpu_stats`/`precpu_stats` pair (e.g. delta 1e8 / sys-delta 1e9 × 4 cpus = 40%); `system_delta ≤ 0` → 0; memory cache-subtraction + percent; network/block-io summation across entries; missing `networks`/`blkio_stats`/`memory_stats` → 0 (no throw).
- `streamContainerStats`: two JSON objects split across byte chunks (newline mid-buffer) → two `ContainerStats`; a malformed line is skipped.
- `StatsNotifier` (real `DockerApiClient` over a fake `Transport` streaming canned NDJSON): samples update `latest` + grow `cpuHistory`/`memHistory`; the windows cap at `kStatsWindow`; a stream error → `StatsStatus.error`.
- `ContainerStatsScreen` (fake transport): renders the current CPU%/memory/network/block numbers from a sample (loading spinner before the first); the Stats button on `ContainerDetailScreen` opens it. (fl_chart rendering itself is not deep-tested.)

## 9. Dependencies
- **Add:** `fl_chart` (line charts). No others.

## 10. Open questions / to confirm during planning
- `fl_chart` current major version: pin the latest stable in the plan; the minimal `LineChart` API (`LineChartData`/`LineChartBarData`/`FlSpot`) is stable across recent majors — adapt member names if the installed version differs.
- cgroup v2 memory: some daemons omit `stats.cache`; the `inactive_file` fallback covers most, else `used == usage` — acceptable.
- Whether to also gate the Stats button on running state (a stopped container yields no stats); default: always show the button, let the screen show loading/empty — simpler, and a just-stopped container still benefits.
