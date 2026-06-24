# docker-mobile Phase 1C-3a — Networks — Design Spec

**Date:** 2026-06-25
**Status:** Approved (brainstorming) — proceeding to plan
**Builds on:** Phase 0/1A/1B/1C-1/1C-2 (on `main`). C3 = networks (this slice, C3a) + volumes (C3b). C3a also delivers the reusable `KeyValueEditor` widget that C3b reuses.

---

## 1. Summary

C3a adds network management: a **Networks** bottom-nav tab with list, detail (driver/scope/IPAM/connected containers/labels/options), **rich create** (driver + dynamic IPAM subnets + labels + options), remove, and prune. It introduces a reusable `KeyValueEditor` widget for editing `Map<String,String>` (labels and driver options).

## 2. Goals / Non-goals

**Goals**
- `KeyValueEditor` widget (StatefulWidget, owns + disposes its controllers).
- Models `DockerNetwork` (list) + `NetworkDetail`.
- `DockerApiClient`: listNetworks, inspectNetwork, createNetwork (rich body), removeNetwork, pruneNetworks.
- `NetworksScreen`, `NetworkDetailScreen`, `NetworkCreateSheet` (rich form); a **Networks** tab on `HomeScreen`.

**Non-goals (this slice)**
- Volumes (C3b), system (C4).
- Connect/disconnect a container to a network (later enhancement).
- Network update; swarm-scoped network create specifics beyond passing the driver through.

## 3. Scope decisions (locked)

- **Create richness:** rich — name, driver (bridge/overlay/macvlan/ipvlan), internal/attachable/enableIPv6 toggles, a **dynamic IPAM Config list** (subnet/gateway/ipRange rows), Labels (`KeyValueEditor`), Options (`KeyValueEditor`).
- **Status codes:** create = `201`; remove = `204`; prune = `200`; list/inspect = `200`; non-success → `DockerApiException` (a `403` on removing a predefined `bridge/host/none` is surfaced as such).
- **Nav:** add a Networks tab to the existing bottom nav (now Containers | Images | Networks).
- **Dialog/controller discipline:** every form/dialog that owns `TextEditingController`s is a `StatefulWidget` that disposes them in `State.dispose` (never `try/finally` around `showDialog`).

## 4. Architecture

```
HomeScreen bottom nav: Containers | Images | Networks(new)
  NetworksScreen (list)  --app-bar--> Create -> NetworkCreateSheet (rich form) ; Prune (confirm) ; refresh
       │ tap
       ▼
  NetworkDetailScreen (driver/scope/flags/IPAM/containers/labels/options) --Remove(confirm)-->
```

## 5. Components

### 5.1 Reusable widget — `lib/src/ui/widgets/key_value_editor.dart`
- `class KeyValueEditor extends StatefulWidget { final String title; final void Function(Map<String,String>) onChanged; }` — renders a titled list of key/value `TextField` rows with an **Add** button and a per-row **remove**; calls `onChanged` with the current non-empty-key map whenever a field changes or a row is added/removed. Owns all controllers; disposes them in `State.dispose`.

### 5.2 Models — `lib/src/api/models/docker_network.dart`
- `DockerNetwork` (from `GET /networks`): `id`, `name`, `driver`, `scope`.
- `IpamConfig`: `subnet`, `gateway`, `ipRange` (all `String?`).
- `NetworkDetail` (from `GET /networks/{id}`): `id`, `name`, `driver`, `scope`, `internal`, `attachable`, `enableIPv6`, `String ipamDriver`, `List<IpamConfig> ipam`, `List<({String name, String ipv4})> containers` (from `Containers` map), `Map<String,String> labels`, `Map<String,String> options`.

### 5.3 DockerApiClient — additions
- `Future<List<DockerNetwork>> listNetworks()` — GET `/networks` (200).
- `Future<NetworkDetail> inspectNetwork(String id)` — GET `/networks/{id}` (200).
- `Future<String> createNetwork({required String name, String driver = 'bridge', bool internal = false, bool attachable = false, bool enableIPv6 = false, List<IpamConfig> ipam = const [], Map<String,String> labels = const {}, Map<String,String> options = const {}})` — POST `/networks/create` (201) → returns `Id`. Body: `{Name, Driver, Internal, Attachable, EnableIPv6, IPAM:{Driver:'default', Config:[{Subnet,Gateway,IPRange} (only non-null keys)]}, Labels, Options}`. Omits empty `Labels`/`Options`/`Config` for cleanliness.
- `Future<void> removeNetwork(String id)` — DELETE `/networks/{id}` (204).
- `Future<void> pruneNetworks()` — POST `/networks/prune` (200).

### 5.4 State
- `networksProvider = FutureProvider<List<DockerNetwork>>`; `networkDetailProvider = FutureProvider.family<NetworkDetail, String>`.

### 5.5 UI
- `NetworksScreen` — list (`name` · `driver` · `scope`); app-bar **Create** (push `NetworkCreateSheet`), **Prune** (confirm dialog), refresh; tap → `NetworkDetailScreen`.
- `NetworkDetailScreen` — driver/scope, internal/attachable/IPv6 flags, IPAM (subnet/gateway/ipRange rows), connected containers (name → ipv4), labels, options; **Remove** (confirm). On the `403`/`409` error → snackbar with the message.
- `NetworkCreateSheet` (StatefulWidget) — name field; driver `DropdownButton` (bridge/overlay/macvlan/ipvlan); internal/attachable/enableIPv6 `SwitchListTile`s; a **dynamic IPAM list** (each row: subnet/gateway/ipRange fields + remove; an Add button); `KeyValueEditor` for Labels and for Options; a **Create** button (disabled if name empty). On create → `createNetwork(...)` → invalidate `networksProvider`, pop, success snackbar; error → snackbar.
- `HomeScreen` — add the Networks `NavigationDestination` + `NetworksScreen` in the `IndexedStack`.

## 6. Data flow & error handling
- List/detail via providers. Create/remove/prune → client → on success invalidate `networksProvider` (+ `networkDetailProvider` for the affected id) + success snackbar; `DockerApiException` → error snackbar (predefined-network `403`, in-use `409` surfaced verbatim).
- Create validates a non-empty trimmed name client-side before calling the API.
- All controllers (name, IPAM rows, KeyValueEditor) disposed on sheet dispose.

## 7. File structure
```
app/lib/src/ui/widgets/key_value_editor.dart    # KeyValueEditor
app/lib/src/api/models/docker_network.dart        # DockerNetwork + IpamConfig + NetworkDetail
app/lib/src/api/docker_api_client.dart            # + 5 network methods
app/lib/src/state/providers.dart                  # + networks providers
app/lib/src/ui/network_create_sheet.dart          # NetworkCreateSheet
app/lib/src/ui/network_detail_screen.dart         # NetworkDetailScreen
app/lib/src/ui/networks_screen.dart               # NetworksScreen
app/lib/src/ui/home_screen.dart                   # + Networks tab
app/test/...                                        # mirrors the above
```

## 8. Testing
- `KeyValueEditor` widget: Add a row, type a key+value → `onChanged` map contains it; remove a row → map updates; an empty-key row is excluded.
- Models: `DockerNetwork`/`NetworkDetail` parse driver/scope/flags, IPAM `Config`, `Containers` map → name+ipv4, labels/options; tolerate missing fields.
- Client: `createNetwork` asserts the exact POST body (Driver, IPAM.Config list with only non-null keys, Labels, Options, flags); `removeNetwork`→`DELETE /networks/{id}` 204; `pruneNetworks`→`POST /networks/prune` 200; a `403` on remove → `DockerApiException`.
- Widgets: `NetworksScreen` (renders a fake list + Prune confirm), `NetworkDetailScreen` (renders detail + Remove confirm), `NetworkCreateSheet` (enter name + add an IPAM subnet + a label, tap Create → assert the client received the expected name/subnet/label), `HomeScreen` (Networks destination present, selecting it sets index 2).

## 9. Dependencies
None new.

## 10. Open questions / to confirm during planning
- `createNetwork` IPAM omission rules: send `IPAM` only when there is at least one config row (else let the daemon default); confirm during plan.
- Whether the create sheet is a pushed screen or a modal sheet (default: pushed screen, given the form length).
- Predefined-network removal: rely on the daemon `403` rather than client-side disabling (simpler, accurate).
