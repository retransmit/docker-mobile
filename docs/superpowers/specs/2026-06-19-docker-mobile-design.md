# docker-mobile — Design Spec

**Date:** 2026-06-19
**Status:** Approved (brainstorming) — pending user review of written spec
**Author:** Brainstormed with the user

---

## 1. Summary

`docker-mobile` is an **open-source, self-hostable mobile app (Flutter, iOS + Android) that gives full control over Docker** from a phone — the entire Docker Engine API surface, not a curated subset. It connects to Docker host(s) over **three interchangeable transports**: a self-hosted companion **agent** (HTTPS + WebSocket), **direct TCP + TLS** (mutual-TLS to `dockerd:2376`), and **SSH** (`ssh://` transport). The app speaks the **raw Docker Engine API through a single client** across all transports, so feature coverage is identical everywhere and new Docker API features work without per-transport work.

The companion agent is optional but recommended: it is a **transparent authenticated reverse-proxy + WebSocket⇄hijacked-stream bridge**, and additionally provides **agent-only superpowers** — device pairing, a multi-host directory, and server-side **event-watching that drives push notifications / alerts**.

## 2. Goals / Non-goals

**Goals**
- Control **every** part of Docker reachable via the Engine API (containers, images, networks, volumes, exec, system, events, registry, build, compose/stacks, full Swarm, plugins, daemon config).
- Three first-class transports (agent, TCP+TLS, SSH) behind one abstraction.
- Real-time everything: live logs, live stats, live events, interactive exec terminal.
- Secure by default; honest about the risks of exposing the Docker API.
- Open-source friendly: self-hostable, no mandatory cloud, strong defaults, good docs.

**Non-goals (initially)**
- Multi-user accounts / RBAC product features (single operator assumed; per-device tokens only). May come later.
- Managing the host OS beyond Docker.
- A hosted SaaS backend. Push delivery integrates with self-hostable services (ntfy/Gotify/webhook) and optionally FCM/APNs.

## 3. Audience

Open-source community tool that individuals **self-host against their own daemons**. Design for strong defaults, flexible configuration, and clear security guidance.

## 4. Architecture (Option C — Hybrid)

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│   Flutter App (iOS/Android) │         │  Docker host(s)              │
│                             │         │                              │
│  UI (Riverpod state)        │         │   ┌────────────────────────┐ │
│  ───────────────────────    │         │   │ docker-mobile-agent    │ │
│  DockerApiClient  ──────────┼──(C)────┼──▶│ (Go) authn + reverse   │ │
│   (one Engine-API client)   │  HTTPS  │   │ proxy + WS⇄hijack +    │ │
│                             │   +WS   │   │ event watcher/push     │ │
│  TransportLayer (abstract): │         │   └──────────┬─────────────┘ │
│   • AgentTransport  ────────┘         │              │ /var/run/      │
│   • TcpTlsTransport ───────(B)────────┼──────────────┤ docker.sock    │
│   • SshTransport    ───────(A)────────┼──▶ ssh ──────┘ (or npipe)     │
│                             │         │              dockerd          │
│  Secure storage (certs,     │         └──────────────────────────────┘
│   tokens, keys, biometrics) │
└─────────────────────────────┘
   A = SSH-forwarded socket   B = direct TCP+TLS:2376   C = agent (recommended)
```

**Rationale for Option C:** one Docker API client reused by every transport ⇒ automatic feature parity + future-proofing; a small, auditable, secure agent; and room for phone-first superpowers (alerts/push, multi-host) without forking the client.

## 5. Components

### 5.1 Flutter app (`/app`)
- **State management:** Riverpod.
- **`DockerApiClient`:** one client implementing the full Engine API, built on top of a `Transport`.
- **`Transport` interface:** sends Engine-API HTTP requests and opens raw bidirectional streams (for hijacked exec/attach and chunked log/stat/event streams). Three implementations:
  - `AgentTransport` — HTTPS to the agent; streams via WebSocket.
  - `TcpTlsTransport` — `dart:io` `SecureSocket` to `:2376` with client cert/key/CA (mutual TLS); streams read from the raw socket; performs the HTTP/1.1 connection upgrade for hijacked streams itself.
  - `SshTransport` — SSH connection (e.g. `dartssh2`) that forwards to the daemon socket; same raw-stream handling.
- **Secure storage:** `flutter_secure_storage` (iOS Keychain / Android Keystore) for certs, tokens, SSH keys; **biometric app-lock** + auto-lock.
- **Terminal:** xterm-style emulator widget for exec/attach with TTY resize.
- **Connection manager:** saved hosts, per-host transport config, quick host switching.

### 5.2 `docker-mobile-agent` (`/agent`)
- **Language:** Go (Docker SDK is Go-native; single static binary; trivial to ship as a container). Mounts `/var/run/docker.sock` (or Windows named pipe).
- **Responsibilities:**
  1. **Auth & pairing** — QR / one-time-code pairing issues per-device tokens (listable, revocable); optional role scope (read-only vs full).
  2. **Transparent reverse proxy** — forwards authenticated requests to the Docker socket unchanged.
  3. **Stream bridge** — WebSocket ⇄ Docker hijacked connections (exec/attach) and chunked streams (logs/stats/events).
  4. **Event watcher / push** — watches the events stream server-side and emits alerts via ntfy/Gotify/webhook and/or FCM/APNs.
- **Distribution:** published container image + static binaries; sample `docker run` / compose snippet.

### 5.3 Shared API model (`/shared`)
- Docker Engine API request/response types (targeting current Engine API, see Appendix A), used by `DockerApiClient`. Prefer codegen from the Engine API OpenAPI/swagger where practical; otherwise hand-maintained typed models.

## 6. Security & pairing

- **Agent:** TLS always — self-signed cert **pinned at pairing**, or behind the user's own reverse proxy / Let's Encrypt. **Pairing via QR / one-time code** → per-device token; tokens listable + revocable; optional **read-only vs full** role. Rate-limiting; proxy refuses all Docker traffic until authenticated.
- **TCP+TLS:** import **client cert + key + CA** for Docker mutual TLS (`:2376`); stored in the OS secure enclave. Loud warning when pointed at plaintext `:2375`.
- **SSH:** key-based auth with **host-key verification (TOFU + pinning)**; private keys in Keychain/Keystore; optional passphrase via biometrics.
- **App:** all secrets in secure storage; biometric lock + auto-lock; no secrets in logs/plaintext.
- **Honest framing:** Docker API access ≈ root on the host. The app steers users toward agent + TLS + auth and warns on insecure configurations.

## 7. Real-time streaming

- **Logs / stats / events:** chunked HTTP streams. Over the **agent** → WebSocket frames; over **TCP+TLS / SSH** → raw socket reads. Stats charts throttle; logs support follow/tail/since/until + client-side search & filter.
- **stdcopy demux (must implement correctly):** when a container/exec has **no TTY**, stdout/stderr are multiplexed with an 8-byte frame header — `byte0` = stream type (0=stdin, 1=stdout, 2=stderr), `bytes1-3` = `0x00` padding, `bytes4-7` = payload length (uint32 **big-endian**), followed by the payload; frames repeat. When **TTY is set there is no header** — a single raw merged stream. The client (or agent) must check the `Tty` flag via inspect to decide whether to demux. Applies to logs (non-TTY), attach, and exec output.
- **Exec / attach (crux):** Docker **hijacks** the HTTP connection (`Upgrade: tcp` → `101`) into a raw bidirectional stream. **`attach` has a WebSocket variant (`GET /containers/{id}/attach/ws`) but `exec` does NOT** — so for the agent transport the Go agent **must bridge WebSocket ⇄ the hijacked exec connection** (this is a primary reason the agent exists). Over TCP+TLS / SSH the app performs the HTTP upgrade on its own raw socket. UI is an xterm terminal with TTY resize.
- **Push notifications / alerts:** agent **watches events server-side** and pushes alerts (container died/restarted/unhealthy, image pulled, etc.) via **FCM/APNs** and/or self-hostable **ntfy / Gotify / webhook**. Without an agent, falls back to foreground/background polling.

## 8. Feature catalogue (full coverage, phase-tagged)

Phases: **P1** = milestone 1 core daily-driver, **P2** = observability/registry/multi-host, **P3** = build/compose/swarm/plugins, **P4** = polish.

| Domain | Operations | Phase |
|---|---|---|
| **Containers** | list, inspect, create/run, start, stop, restart, kill, pause/unpause, rename, update (cpu/mem/restart-policy), remove, prune, wait, top, diff, export, cp (get/put archive), port map view, resize TTY | P1 |
| **Container logs** | follow/tail/since/until, stdout-stderr demux, search & filter, download | P1 |
| **Exec / terminal** | exec create+start (interactive TTY), attach, resize, one-off commands | P1 |
| **Images** | list, inspect, history, pull, tag, remove, prune, load/import, save/export, distribution (manifest) | P1 |
| **Networks** | list, inspect, create (bridge/overlay/macvlan/ipvlan/host/none, IPAM), connect/disconnect, remove, prune | P1 |
| **Volumes** | list, inspect, create (drivers/opts), remove, prune | P1 |
| **System** | info, version, ping, df (disk usage), system prune, data usage breakdown | P1 |
| **Stats / monitoring** | live stats stream (cpu/mem/net/blkio) → charts, per-container & host overview | P2 |
| **Events** | system events stream → live UI refresh + alert source | P2 |
| **Registry / auth** | login/logout, credential store, search, pull/push with creds | P2 |
| **Contexts / multi-host** | manage multiple daemon endpoints, switch hosts, per-host saved connection | P2 |
| **Image build / BuildKit** | build from Dockerfile + context (tar upload), build args, progress stream, cache | P3 |
| **Compose / stacks** | parse compose file, up/down/ps/logs/scale, deploy as stack | P3 |
| **Swarm** | init/join/leave/unlock; nodes (list/inspect/update/remove); services (CRUD/scale/rollback/logs); tasks (list/inspect/logs); secrets (CRUD); configs (CRUD) | P3 |
| **Plugins** | list, install, enable/disable, configure, remove | P3 |
| **Daemon config** | view/inspect daemon settings, runtime info (read-first; careful writes) | P3 |

> Appendix A enumerates the concrete Engine API endpoints per domain that the client must cover to claim "full control."

## 9. Phased roadmap

- **Phase 0 — Scaffold:** monorepo (`/app` Flutter, `/agent` Go, `/shared` API model + codegen), CI, `DockerApiClient` + `Transport` interface, agent skeleton (auth + transparent proxy), first real call: connect → list containers. TDD from here on.
- **Phase 1 — Core daily-driver (Milestone 1):** full container/image lifecycle, networks, volumes, system, **live logs + search**, **exec terminal**. Build the **agent transport first**, then **TCP+TLS**, then **SSH**.
- **Phase 2 — Observability & reach:** stats charts, events feed, **push notifications/alerts**, registry/auth, multi-host/contexts.
- **Phase 3 — Build & orchestrate:** image build/BuildKit, Compose/stacks, full Swarm, plugins, daemon config.
- **Phase 4 — Polish:** home-screen widgets/quick actions, theming, tablet layout, accessibility, optional desktop/web targets.

Each phase gets its own spec → plan → implementation cycle. **Only Phase 0 + Phase 1 are fully planned now.**

## 10. Testing strategy

- TDD (superpowers `test-driven-development`) for both `/app` (Dart `flutter_test`, integration tests) and `/agent` (Go `testing`).
- Agent integration tests run against a real Docker socket in CI (dind / Docker-in-Docker) to validate proxy + stream bridging.
- Transport conformance suite: the same Engine-API test matrix run across all three transports to guarantee parity.

## 11. Open questions / to confirm during planning

- Exact Engine API version floor to target (and minimum Docker version supported).
- SSH library choice (`dartssh2` vs alternative) and its raw-channel/stream maturity for hijacked exec.
- Codegen vs hand-written models for `/shared`.
- Push: default to ntfy-style self-host first; FCM/APNs as opt-in (requires app-store push entitlements + a relay).
- License (e.g. Apache-2.0 vs MIT vs AGPL) — affects contribution & hosting expectations.

## Appendix A — Engine API endpoint map

Target: **Docker Engine API v1.45+ (Docker 25+)**; negotiate version via `GET /version` and degrade gracefully on older daemons. Endpoints below are the control surface the `DockerApiClient` must cover for "full control." (Reconciled against the API-surface research; this is the authoritative checklist.)

**Containers** — `GET /containers/json` (list) · `POST /containers/create` · `GET /containers/{id}/json` (inspect) · `GET /containers/{id}/top` · `GET /containers/{id}/logs` (stream) · `GET /containers/{id}/changes` (diff) · `GET /containers/{id}/export` · `GET /containers/{id}/stats` (stream) · `POST /containers/{id}/resize` · `POST /containers/{id}/start|stop|restart|kill|pause|unpause|rename|update` · `POST /containers/{id}/attach` (hijack) · `GET /containers/{id}/attach/ws` · `POST /containers/{id}/wait` · `DELETE /containers/{id}` · `HEAD|GET|PUT /containers/{id}/archive` (cp) · `POST /containers/prune`

**Exec** — `POST /containers/{id}/exec` (create) · `POST /exec/{id}/start` (hijack) · `POST /exec/{id}/resize` · `GET /exec/{id}/json` (inspect)

**Images & build** — `GET /images/json` (list) · `POST /images/create` (pull/import) · `GET /images/{name}/json` (inspect) · `GET /images/{name}/history` · `POST /images/{name}/push` · `POST /images/{name}/tag` · `DELETE /images/{name}` · `GET /images/search` · `POST /images/prune` · `POST /commit` (container→image) · `GET /images/get`, `GET /images/{name}/get` (save) · `POST /images/load` · `GET /distribution/{name}/json` (manifest) · `POST /build` + `POST /build/prune` (BuildKit via `POST /session` gRPC hijack)

**Networks** — `GET /networks` · `GET /networks/{id}` · `POST /networks/create` · `POST /networks/{id}/connect|disconnect` · `DELETE /networks/{id}` · `POST /networks/prune`

**Volumes** — `GET /volumes` · `POST /volumes/create` · `GET /volumes/{name}` · `DELETE /volumes/{name}` · `POST /volumes/prune`

**System** — `GET|HEAD /_ping` · `GET /version` · `GET /info` · `GET /events` (stream) · `GET /system/df` · `POST /auth` (registry credential check). System-wide prune is orchestrated client-side over the per-resource `prune` endpoints.

**Swarm** — `GET /swarm` · `POST /swarm/init|join|leave|update|unlock` · `GET /swarm/unlockkey` · Nodes: `GET /nodes`, `GET|DELETE /nodes/{id}`, `POST /nodes/{id}/update` · Services: `GET /services`, `POST /services/create`, `GET /services/{id}`, `POST /services/{id}/update`, `DELETE /services/{id}`, `GET /services/{id}/logs` · Tasks: `GET /tasks`, `GET /tasks/{id}`, `GET /tasks/{id}/logs` · Secrets: `GET /secrets`, `POST /secrets/create`, `GET|DELETE /secrets/{id}`, `POST /secrets/{id}/update` · Configs: `GET /configs`, `POST /configs/create`, `GET|DELETE /configs/{id}`, `POST /configs/{id}/update`

**Plugins** — `GET /plugins` · `GET /plugins/privileges` · `POST /plugins/pull` · `GET /plugins/{name}/json` · `POST /plugins/{name}/enable|disable|upgrade|push|set` · `POST /plugins/create` · `DELETE /plugins/{name}`

**Compose / stacks (client-side, not an Engine endpoint)** — Compose is a client concern: the app parses the Compose spec and orchestrates the underlying `create`/`connect`/`volume`/`secret`/`config` calls. On Swarm, `docker stack deploy` ≈ translating Compose into `services/networks/volumes/secrets/configs` create/update calls. This is built on top of the endpoints above, with no dedicated daemon API.

**Sessions / BuildKit** — `POST /session` (BuildKit attachable session, gRPC over hijacked connection) underpins modern `POST /build`; required for build cache, secrets, SSH-forwarding in builds.

## Appendix B — Transport, framing & least-privilege notes (from research)

These cross-cutting findings shape the client/agent implementation:

- **The Engine API has no users/roles/RBAC.** A working connection is **root-equivalent** on the host. "Securing the transport" *is* the security model. Per-device tokens (agent) and mTLS/SSH credentials are therefore root-grade secrets → secure enclave only.
- **Least-privilege options (agent-side / optional):** scope the app's blast radius with a **socket proxy** (e.g. an HAProxy-style allowlist of endpoints/methods — `CONTAINERS=1`, `POST=0`, etc.) and/or an **AuthZ plugin** (`--authorization-plugin`, called pre/post every request, can allow/deny by method+path and, under mTLS, client-cert CN). The agent should expose an optional read-only role and may front the daemon with such a proxy.
- **`daemon.json` is NOT writable via the Engine API.** Reading config is via `GET /info` + `GET /version`; *changing* it (storage driver, TLS, hosts, GC, registries…) means editing the host file + `SIGHUP`/restart — an **agent/SSH operation**, not an API call. Phase-3 "daemon config" is therefore read-first, with writes only on the agent/SSH transports.
- **System prune, contexts, compose, and stacks have no server endpoint** — all are client-side abstractions the app/agent must implement:
  - *System prune* = orchestrate `containers/networks/images/(volumes)/build` prune calls in sequence.
  - *Contexts* = the multi-host profile model to replicate: `{ Host (unix/npipe/tcp/ssh), TLS material, optional k8s }` — maps 1:1 to our saved-connection model.
  - *Compose* = parse the Compose spec and create/wire networks→volumes→containers, labeling with `com.docker.compose.{project,service,container-number}`.
  - *Stacks* (Swarm) = translate Compose into `services/networks/volumes/secrets/configs`, labeling with `com.docker.stack.namespace=<name>`; `stack ls/ps/rm` filter by that label.
- **Streamed pull/push/build responses keep HTTP `200` while reporting errors *in-stream*** (`{"error":...}` / `errorDetail`). The client must parse the progress stream and surface in-band errors, not rely on status codes.
- **Universal conventions:** version-prefix paths (`/v1.43/...`) and negotiate `min(client, server)` from `GET /version`/`_ping`; `filters` is a URL-encoded JSON `map[string][]string`; durations in bodies are **int64 nanoseconds**, sizes are bytes, `NanoCpus` is billionths of a CPU; registry auth rides the `X-Registry-Auth` header (and `X-Registry-Config` map for builds), which authenticates to *registries*, not the daemon.
- **API version note:** the research was compiled against the frozen **v1.43** swagger (Docker 24.0); the spec targets **v1.45+** with runtime negotiation, so a few version-sensitive fields (e.g. exact `POST /build/prune` params, `platform` on push) must be confirmed against the daemon's advertised version at runtime rather than hardcoded.
