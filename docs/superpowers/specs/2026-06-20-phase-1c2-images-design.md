# docker-mobile Phase 1C-2 — Images + Top-Level Navigation — Design Spec

**Date:** 2026-06-20
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 0/1A/1B/1C-1 (on `main`). Second slice of sub-project C. C = C1 containers (done), **C2 images**, C3 networks/volumes, C4 system.

---

## 1. Summary

C2 adds image management and the app's first **top-level navigation**: a bottom-nav `HomeScreen` hosting Containers and Images tabs. Images get a list, a detail screen (inspect basics + layer history), and actions — **pull (with live streamed progress)**, **tag**, **remove**, and **prune**. Pull introduces a streaming-POST transport primitive reusable by build/push/load later.

## 2. Goals / Non-goals

**Goals**
- `HomeScreen` with `BottomNavigationBar` (Containers | Images); `ConnectionScreen` lands here.
- `Transport.postStream` (cancelable streamed POST).
- Image models + `DockerApiClient` methods: list, inspect, history, pull (stream), tag, remove, prune.
- `ImagesScreen`, `ImageDetailScreen`, and a `PullSheet` with live per-layer progress.

**Non-goals (this slice)**
- Image **build** (BuildKit), **save/load/export**, registry **search**, push — later slices.
- Networks/volumes/system (C3/C4); container create.

## 3. Scope decisions (locked)

- **Navigation:** bottom-nav `HomeScreen` (no app bar of its own) wrapping an `IndexedStack` of the two tab screens (each keeps its own Scaffold/app bar). C3/C4 append tabs.
- **Pull:** live progress view (`PullSheet`) streaming `POST /images/create`; reuse the streaming transport.
- **Streaming POST:** add `Transport.postStream`; do NOT shoehorn pull through the GET-only `stream`.
- **Remove options:** `force` + `noprune`. **Prune:** dangling-only (default) vs all (untagged) via the `dangling` filter, with a confirm.

## 4. Architecture

```
ConnectionScreen --connect--> HomeScreen (BottomNavigationBar)
   tab 0: ContainersScreen (existing)      tab 1: ImagesScreen (new)
                                                │ tap -> ImageDetailScreen (history + actions)
                                                │ app-bar: Pull -> PullSheet, Prune, refresh
   PullSheet: postStream POST /images/create?fromImage=&tag=  -> Stream<PullEvent> (per-layer progress)
```

## 5. Components

### 5.1 Transport (app)
- `Transport.postStream(String path, {Map<String,String>? query, Object? body}) → Stream<List<int>>` — same cancelable `StreamController` pattern as `stream`, but issues a POST (JSON body when provided); non-200 → `TransportException`; cancel closes the connection. `AgentTransport` implements; existing fakes get a stub.

### 5.2 Models (app)
- `DockerImage` (`lib/src/api/models/docker_image.dart`): `id`, `List<String> repoTags`, `int size`, `int created` (epoch seconds). From `GET /images/json` (`Id`, `RepoTags`, `Size`, `Created`).
- `ImageHistoryLayer`: `id`, `int created`, `String createdBy`, `int size`, `List<String> tags`. From `GET /images/{id}/history`.
- `ImageDetail`: `id`, `List<String> repoTags`, `String architecture`, `String os`, `int size`, `int created` (epoch via `Created` RFC3339 → parse to seconds or keep string), `List<String> env`, `List<String> exposedPorts`. From `GET /images/{id}/json`.
- `PullEvent` (`lib/src/api/models/pull_event.dart`): `String status`, `String? id`, `int? current`, `int? total`, `String? error`. From one `/images/create` JSON line (`status`, `id`, `progressDetail.{current,total}`, `error`).

### 5.3 DockerApiClient (app) — additions
- `Future<List<DockerImage>> listImages()` — GET `/images/json`.
- `Future<ImageDetail> inspectImage(String id)` — GET `/images/{id}/json`.
- `Future<List<ImageHistoryLayer>> imageHistory(String id)` — GET `/images/{id}/history`.
- `Stream<PullEvent> pullImage(String image, {String tag = 'latest'})` — `postStream('/images/create', query:{fromImage:image, tag})`; split the chunked body into newline/object-delimited JSON; emit `PullEvent` per line.
- `Future<void> tagImage(String id, {required String repo, String tag = 'latest'})` — POST `/images/{id}/tag?repo=&tag=` (201 ok).
- `Future<void> removeImage(String id, {bool force = false, bool noprune = false})` — DELETE `/images/{id}?force=&noprune=` (200 ok).
- `Future<void> pruneImages({bool danglingOnly = true})` — POST `/images/prune?filters={"dangling":["true"|"false"]}` (200 ok).

### 5.4 State (app)
- `imagesProvider = FutureProvider<List<DockerImage>>` → `listImages`.
- `imageDetailProvider`/`imageHistoryProvider = FutureProvider.family<…, String>` by id.

### 5.5 UI (app)
- `HomeScreen` (`lib/src/ui/home_screen.dart`) — `ConsumerStatefulWidget`; `Scaffold(bottomNavigationBar: BottomNavigationBar(items: Containers, Images), body: IndexedStack(index, [ContainersScreen(), ImagesScreen()]))`. `ConnectionScreen._connect` pushes `HomeScreen`.
- `ImagesScreen` — list (repo:tag or `<none>`, short id, human size, age); app-bar actions: **Pull** (opens `PullSheet`), **Prune** (confirm dangling vs all), refresh. Tap row → `ImageDetailScreen`.
- `ImageDetailScreen` — inspect basics (arch/os/size/created/exposed ports/env) + history layers; actions: **Tag** (dialog: repo + tag) and **Remove** (confirm with force + noprune switches). Snackbar + refresh after actions.
- `PullSheet` — a text field for the image ref (parsed into image + tag on `:`), a Pull button; on start, streams `pullImage` into an overall status line + per-layer rows (status + a progress bar when `total` known); shows the final result or an error; leaving cancels the stream.

## 6. Data flow & error handling
- Tabs via `IndexedStack` keep both screens alive; switching is instant.
- Pull: in-stream `{"error":...}` (HTTP stays 200) → `PullEvent.error` → `PullSheet` shows failure. Connection drop → stream error → failure state with retry.
- tag/remove/prune failures → `DockerApiException` → error snackbar; success → invalidate `imagesProvider` (and detail) + success snackbar.
- Leaving `PullSheet` cancels the `postStream` subscription (closes the connection).

## 7. File structure
```
app/lib/src/transport/transport.dart            # + postStream
app/lib/src/transport/agent_transport.dart       # + postStream
app/lib/src/api/models/docker_image.dart          # DockerImage
app/lib/src/api/models/image_detail.dart          # ImageDetail + ImageHistoryLayer
app/lib/src/api/models/pull_event.dart            # PullEvent
app/lib/src/api/docker_api_client.dart            # + 7 image methods
app/lib/src/state/providers.dart                  # + images providers
app/lib/src/ui/home_screen.dart                   # HomeScreen (bottom nav)
app/lib/src/ui/images_screen.dart                 # ImagesScreen
app/lib/src/ui/image_detail_screen.dart           # ImageDetailScreen
app/lib/src/ui/pull_sheet.dart                    # PullSheet
app/lib/src/ui/connection_screen.dart             # land on HomeScreen
app/test/...                                        # mirrors the above
# + postStream stub added to existing Transport fakes
```

## 8. Testing
- `Transport.postStream` — POST + bearer + streamed bytes + cancel (loopback / MockClient.streaming).
- Models — `DockerImage`/`ImageDetail`/`ImageHistoryLayer`/`PullEvent` parsing incl. an error line and `<none>` repo tags.
- `DockerApiClient` — fakes assert routes/queries + streaming parse: `pullImage` over a multi-line progress stream yields the right `PullEvent`s incl. an error; `removeImage` → `DELETE ?force=&noprune=`; `tagImage` → `POST .../tag?repo=&tag=`; `pruneImages(danglingOnly:false)` → the `{"dangling":["false"]}` filter.
- Widgets — `HomeScreen` switches tabs (tap Images → `ImagesScreen` shows); `ImagesScreen` renders a fake list + Prune confirm dialog; `ImageDetailScreen` shows history + Remove confirm; `PullSheet` renders streamed progress lines and surfaces an error event.

## 9. Dependencies
None new. (Human-size/age formatting is a small local helper, not a package.)

## 10. Open questions / to confirm during planning
- Exact `/images/create` line delimiting (newline-delimited JSON vs concatenated objects); parse defensively (accumulate + decode per object).
- `ImageDetail.created`: keep as the raw RFC3339 string vs parse; keep raw for display in this slice.
- Whether `PullSheet` is a modal bottom sheet or a pushed screen (default: pushed screen for space; revisit during plan).
