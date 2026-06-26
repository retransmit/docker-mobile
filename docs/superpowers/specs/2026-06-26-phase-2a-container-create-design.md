# docker-mobile Phase 2A — Container Create / Run — Design Spec

**Date:** 2026-06-26
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** All of Milestone 1 (on `main`). First slice of post-Milestone-1 feature work; closes the last major user-facing gap (creating containers, not just managing existing ones).

---

## 1. Summary

Phase 2A lets users **create and run containers** from the app: a rich create form (`POST /containers/create` + optional start), reached from a **+** on the Containers tab and a **Run** button on an image's detail screen, with **offer-to-pull-then-retry** when the image isn't present locally.

## 2. Goals / Non-goals

**Goals**
- `ContainerCreateConfig` — a pure model that builds the Docker create JSON (image, command, env, ports, volume binds, restart policy, labels, network, memory, CPUs).
- `DockerApiClient.createContainer(config, {name}) → String id` (201 → `Id`); reuse `startContainer`.
- `PortMappingEditor` — a reusable row editor (host port / container port / TCP·UDP).
- `CreateContainerScreen` — the rich form; create → optional start → pop + refresh; **pull-if-missing** (404 → pull dialog → retry).
- Entry points: Containers tab **+** FAB; `ImageDetailScreen` **Run** (pre-filled image).

**Non-goals (this slice)**
- Healthcheck, capabilities/devices/sysctls/ulimits, multiple networks, secrets/configs, GPU, tmpfs, user/working-dir, entrypoint override (beyond `Cmd`).
- Editing an existing container's config (Docker requires recreate; out of scope).
- Compose / multi-container; image build.

## 3. Scope decisions (locked)

- **Rich field set:** image, name, command, env, port mappings, volume binds, restart policy, labels, single network, memory (MB), CPUs.
- **Two entry points:** Containers FAB (image typed) + Image-detail Run (image pre-filled).
- **Pull-if-missing:** create `404` "No such image" → confirm dialog → reuse the live pull flow (`pullImage`/`PullSheet`) → retry create automatically.
- **Start after create:** a toggle (default on); when on, `startContainer` after create.
- **Full screen** (pushed `MaterialPageRoute`), not a bottom sheet (the form is long).
- **Reuse:** `KeyValueEditor` for env/labels/volume-binds; `networksProvider` for the network dropdown; the existing pull stream for pull-if-missing.
- **Async/controller discipline:** capture messenger/navigator before awaits; mounted guards; dispose all controllers; `StatefulWidget` editors (carried from prior slices).

## 4. Architecture

```
ContainersScreen  -- [+] FAB --> CreateContainerScreen(image: null)
ImageDetailScreen -- [Run]   --> CreateContainerScreen(image: 'repo:tag')

CreateContainerScreen (form)
  image / name / command / env(KeyValueEditor) / ports(PortMappingEditor) /
  volumes(KeyValueEditor host->container) / restart(dropdown) / labels(KeyValueEditor) /
  network(dropdown <- networksProvider) / memory(MB) / cpus / [Start after create]
  submit:
    config = ContainerCreateConfig(...)
    try id = client.createContainer(config, name: name)
    on DockerApiException(404, "No such image"):
        confirm pull? -> reuse pull flow (pullImage stream) -> retry createContainer
    if start: client.startContainer(id)
    pop; invalidate containersProvider

ContainerCreateConfig (pure)              [lib/src/api/models/container_create_config.dart]
  toJson() -> { Image, Cmd?, Env?, ExposedPorts?, Labels?,
                HostConfig: { PortBindings?, Binds?, RestartPolicy?, NetworkMode?, Memory?, NanoCpus? } }

DockerApiClient.createContainer(config, {name})  -> POST /containers/create?name= (201 -> Id)
```

## 5. Components

### 5.1 Models — `lib/src/api/models/container_create_config.dart`
- `class PortMapping { final String containerPort; final String protocol; final String hostPort; }` (protocol `tcp`/`udp`).
- `class ContainerCreateConfig`:
  - fields: `String image; List<String> cmd; Map<String,String> env; List<PortMapping> ports; Map<String,String> binds /*host->container*/; String? restartPolicy; Map<String,String> labels; String? network; int? memoryBytes; double? cpus;`
  - `static List<String> parseCommand(String)` — whitespace-split (simple; quoted args out of scope, documented).
  - `Map<String,dynamic> toJson()`:
    - `Image`, plus `Cmd` only if non-empty.
    - `Env` = `['$k=$v']` only if non-empty.
    - `ExposedPorts` = `{'$containerPort/$proto': {}}` for each port (only if ports non-empty).
    - `Labels` only if non-empty.
    - `HostConfig` built from the non-empty subset:
      - `PortBindings` = `{'$containerPort/$proto': [{'HostPort': hostPort}]}`.
      - `Binds` = `['$host:$container']`.
      - `RestartPolicy` = `{'Name': restartPolicy}` when set and non-empty.
      - `NetworkMode` = network when set.
      - `Memory` = memoryBytes when set; `NanoCpus` = `(cpus * 1e9).round()` when set.
    - Omit `HostConfig` entirely if it would be empty.

### 5.2 DockerApiClient — addition
- `Future<String> createContainer(ContainerCreateConfig config, {String? name})`:
  - `final resp = await transport.post('/containers/create', query: name == null || name.isEmpty ? null : {'name': name}, body: config.toJson());`
  - `if (resp.statusCode != 201) throw DockerApiException(resp.statusCode, resp.body);`
  - return `(jsonDecode(resp.body) as Map)['Id'] as String`.
- (Reuses existing `startContainer(id)` and `pullImage(image, tag)`.)

### 5.3 PortMappingEditor — `lib/src/ui/widgets/port_mapping_editor.dart`
- `StatefulWidget` owning per-row controllers (host/container) + a per-row protocol toggle; `onChanged(List<PortMapping>)`; an **Add port** button; per-row delete. Mirrors `KeyValueEditor`'s lifecycle (dispose controllers; emit on edit). Rows with an empty container port are dropped from the emitted list.

### 5.4 UI — `CreateContainerScreen`
- `ConsumerStatefulWidget`, optional `String? image` (pre-fill). Controllers: image, name, command, memory, cpus. State: env/labels/binds maps, ports list, restart policy (`String?`), selected network (`String?`), `bool _start = true`. Network dropdown watches `networksProvider` (loading/empty tolerated → just the default "none").
- **Submit** `_create()`:
  1. validate image non-empty (else snackbar).
  2. build `ContainerCreateConfig` from the fields.
  3. `try { id = await client.createContainer(config, name: name) }`.
  4. on `DockerApiException` whose code is `404` (or body contains `No such image`): show a confirm dialog; on confirm, run the pull flow for `image` (reuse `PullSheet`/`pullImage`), then retry `createContainer`; on a still-failing/declined → snackbar, return.
  5. if `_start` → `await client.startContainer(id)`.
  6. capture messenger/navigator before awaits; on success → `ref.invalidate(containersProvider)`, navigator.pop, success snackbar.

### 5.5 Entry points
- `ContainersScreen` — add a `FloatingActionButton` (`Icons.add`) → `CreateContainerScreen()`.
- `ImageDetailScreen` — add a **Run** action (button) → `CreateContainerScreen(image: <repo:tag of this image>)`.

## 6. Data flow & error handling
- Build → create → (404 → pull → retry) → optional start → pop + invalidate `containersProvider`.
- Validation: empty image blocks submit; malformed numeric fields (memory/cpus) are ignored if unparseable (treated as unset).
- `createContainer` non-201 → `DockerApiException`; surfaced as a snackbar (except the handled 404-pull path).
- Pull reuses the existing NDJSON byte-buffered progress; a failed pull → snackbar, stay on the form.

## 7. File structure
```
app/lib/src/api/models/container_create_config.dart   # ContainerCreateConfig + PortMapping
app/lib/src/api/docker_api_client.dart                # + createContainer
app/lib/src/ui/widgets/port_mapping_editor.dart       # PortMappingEditor
app/lib/src/ui/create_container_screen.dart           # CreateContainerScreen
app/lib/src/ui/containers_screen.dart                 # + create FAB
app/lib/src/ui/image_detail_screen.dart               # + Run button
app/test/...                                            # mirrors the above
```

## 8. Testing
- `ContainerCreateConfig.toJson`: image-only (no `HostConfig`); `parseCommand('nginx -g daemon off')` → `['nginx','-g','daemon','off']`; env → `Env:['K=V']`; ports → `ExposedPorts` + `HostConfig.PortBindings` with `'80/tcp'`; binds → `HostConfig.Binds:['/h:/c']`; restart → `RestartPolicy:{Name:'unless-stopped'}`; network → `NetworkMode`; memory/cpus → `Memory`/`NanoCpus` (e.g. `1.5` → `1500000000`); empty maps/lists omit their sections.
- `createContainer`: posts to `/containers/create` with `?name=web` and the JSON body; returns the parsed `Id`; 201-gated (non-201 → `DockerApiException`); no `name` query when name empty.
- `PortMappingEditor`: adding a row + typing host/container/proto emits `[PortMapping(...)]`; deleting removes it; an empty container port is dropped.
- `CreateContainerScreen` (fake transport recording posts): valid submit posts `/containers/create` then `/containers/{id}/start` (start on) and pops; start-off omits the start call; a create returning 404 shows the pull dialog → confirm pulls then retries create; empty image → snackbar, no post.
- Entry points: `ContainersScreen` FAB opens `CreateContainerScreen`; `ImageDetailScreen` Run opens it (image pre-filled — assert the image field).

## 9. Dependencies
None new (reuses `pullImage`, `KeyValueEditor`, `networksProvider`).

## 10. Open questions / to confirm during planning
- 404 detection: prefer matching `resp.statusCode == 404` over body text; confirm the daemon returns 404 (not 500) for a missing image on create, and fall back to a body `contains('No such image')` check.
- Pull reuse: whether to reuse `PullSheet` (modal with live progress) or a lighter inline progress; default **reuse `PullSheet`** so progress UX is consistent.
- `parseCommand` quoting: whitespace-split only this slice (a quoted-arg parser is deferred and documented in the field's helper text).
