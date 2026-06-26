# docker-mobile — End-to-End Manual Smoke Test

The automated suites (`flutter test` → 219 tests, `go test ./...`) run against
**simulated** transports and parsed fixtures. They do **not** exercise the real
network paths: live TLS/SSH sockets, the exec **hijack**, log/stats/event
**streaming**, and a real daemon's responses. This checklist does — run it on a
device/emulator against a real Docker daemon before a release.

> **Status:** not yet executed on hardware in this environment. Everything below
> is prepared and ready; running it needs a device/emulator + a reachable daemon.

---

## 0. Setup

### Prerequisites
- A reachable Docker daemon (Docker Desktop, a Linux host, or a remote box).
- Flutter (`C:\src\flutter`, prefix commands with `export PATH="/c/src/flutter/bin:$PATH"` in Git Bash).
- An Android emulator / iOS simulator / physical device. (Android: accept SDK
  licenses first — `flutter doctor --android-licenses` — see §9.)
- `openssl` (ships with Git for Windows) for the TLS path.
- Go (to run the agent from source) for the agent path.

### Host addressing (important)
The app runs on the device; "host" is **how the device reaches your daemon**:
- **Android emulator → host machine:** `10.0.2.2`. But the **TLS** path pins the
  cert to an IP/SAN, so for TLS bind the daemon on the host's LAN IP and use that
  same IP in the app (and pass it to the cert script).
- **iOS simulator → host machine:** `127.0.0.1`.
- **Physical device:** the host's LAN IP (same Wi-Fi).

### Launch the app
```bash
export PATH="/c/src/flutter/bin:$PATH" && cd app && flutter run
```
The app opens on the **Connections** list (no auth gate).

---

## 1. Transport A — self-hosted Agent (HTTP + bearer)

Run the agent:
```bash
cd agent
# Linux unix socket:
AGENT_TOKEN=dev-secret DOCKER_HOST=unix:///var/run/docker.sock go run ./cmd/agent
# Docker Desktop TCP (enable "Expose daemon on tcp://localhost:2375 without TLS"):
AGENT_TOKEN=dev-secret DOCKER_HOST=tcp://127.0.0.1:2375 go run ./cmd/agent
```
Sanity (from the host):
```bash
curl -s http://127.0.0.1:8080/healthz                                          # ok
curl -s -H "Authorization: Bearer dev-secret" http://127.0.0.1:8080/_ping      # OK
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8080/containers/json # 401 (no token)
```
In the app:
- [ ] **Connections → `+` → Agent.** Name it, Host = device→host address, Port `8080`, Token `dev-secret`, **Use TLS** off.
- [ ] **Save** → returns to the list; the profile shows `agent · <host>`.
- [ ] Tap the profile → connects → lands on the **Containers** tab. (Or use **Save & Connect**.)

## 2. Transport B — direct TCP+TLS (mTLS)

Generate certs and run dockerd with TLS:
```bash
MSYS_NO_PATHCONV=1 ./scripts/gen-tls-certs.sh <DAEMON_IP>   # writes ./certs + prints the dockerd + app instructions
dockerd --tlsverify --tlscacert=certs/ca.pem --tlscert=certs/server-cert.pem --tlskey=certs/server-key.pem -H=0.0.0.0:2376
```
In the app:
- [ ] **`+` → TCP+TLS.** Name, Host `<DAEMON_IP>`, Port `2376`; paste `client-cert.pem`, `client-key.pem`, `ca.pem`; **Allow insecure** OFF. **Save & Connect** → Containers tab.
- [ ] **Negative:** edit the profile, blank/wrong CA, **Allow insecure** OFF → connect fails the handshake; toggle **Allow insecure** ON → connects (documented as MITM-vulnerable).

## 3. Transport C — SSH (dial-stdio)

Requires the `docker` CLI + docker access for the SSH user on the remote; confirm
`ssh user@host docker system dial-stdio` works from a terminal first.
- [ ] **`+` → SSH.** Name, Host, Port `22`, Username; pick **Password** or **Key** (paste PEM + optional passphrase). **Save & Connect**.
- [ ] **First connect** pins the host key silently (no dialog) → Containers tab.
- [ ] **Reconnect** → connects with no dialog (key matches).
- [ ] **Host-key change:** change the server's host key (or edit the profile's pin), reconnect → **"Host key changed"** dialog → **Cancel** aborts; **Trust new key** re-pins and connects.

> Run §4–§8 below over **each** transport at least once (TLS and SSH especially —
> they exercise the real socket + hijack paths).

---

## 4. Containers (Tab 1)

- [ ] List shows containers (running = green play icon, stopped = grey). **Refresh** reloads.
- [ ] Tap a container → **detail**: State, Image, Command, Created, Restart policy, Networks, Ports, Mounts, Env.
- [ ] **Actions** (state-dependent): Start / Stop / Restart / Pause / Unpause / Kill (confirm dialog) / Rename (dialog) / Remove (Force + Remove-volumes switches). Each → success snackbar + list refreshes.
- [ ] **Logs** (live): Follow toggle pauses/resumes; Timestamps toggle; Tail menu (100/500/1000/All); Search filters + highlights; Share opens the sheet; jump-to-bottom FAB; stderr in error color.
- [ ] **Exec** (live PTY): blank command → auto shell (bash→sh); type commands, see live output; resize works; "Session ended (exit N)" + **Restart** on exit. *(This is the hijack path — verify on TLS and SSH.)*
- [ ] **Stats** (live): CPU% chart auto-scales past 100% on multi-core; Memory used/limit/% chart; Network RX/TX; Block I/O R/W; updates ~1/s; stops on leaving.

## 5. Create / run a container

- [ ] Containers **`+` FAB** → Create screen. Fill Image (e.g. `nginx:alpine`), Name, Command; pick Network + Restart policy; set Memory/CPUs; add Env / Ports (host→container, tcp/udp) / Volumes / Labels; **Start after create** on → **Create** → returns to a now-running container.
- [ ] **Pull-if-missing:** use an image not present locally → **"Image not found → Pull"** dialog → live pull-progress dialog (with **Cancel**) → create retries and succeeds.
- [ ] From **Image detail → Run** the create screen opens pre-filled with that image.

## 6. Images (Tab 2)

- [ ] List + **Refresh**. **Pull** sheet: enter `nginx:latest` → live per-layer progress bars → "Pull complete" → list refreshes.
- [ ] Image **detail**: arch/os/size, Created, Exposed ports, Env, History layers. **Tag** (repo+tag dialog), **Remove** (Force/No-prune dialog).
- [ ] **Prune** → All-unused / Dangling dialog → "Pruned".

## 7. Networks (Tab 3) & Volumes (Tab 4)

- [ ] **Network create** sheet: Name, Driver dropdown, Internal/Attachable/IPv6 switches, IPAM subnet rows (CIDR/gateway/range), Labels, Options → **Create**.
- [ ] Network **detail**: flags, IPAM, connected containers, labels/options; **Remove** (confirm).
- [ ] **Volume create**: Name, Driver, Labels, Driver options → **Create**. Volume **detail** + **Remove** (Force switch).
- [ ] **Prune** on each tab.

## 8. System (Tab 5) + Events + Disconnect

- [ ] Dashboard cards: Daemon (version/api/os-arch/kernel/cpus/memory/storage-driver), Containers counts, Disk usage. **Refresh**.
- [ ] **System prune** → dialog with All-unused-images + Also-volumes switches → "Pruned"; resource lists refresh.
- [ ] **Events** (bolt icon, live): generate activity (start/stop a container, pull an image) → events appear newest-first with type/action/target/time; **filter chips** (All/Containers/Images/Networks/Volumes) narrow the feed.
- [ ] **Disconnect** (logout icon) → "Disconnect from this daemon?" → **Disconnect** → returns to the **Connections** list and closes the client. Reconnect from the list works.

## 8a. Profiles lifecycle

- [ ] **Edit** a profile (⋮ → Edit) — the kind selector is hidden, fields pre-filled; **Save** updates it.
- [ ] **Delete** a profile (⋮ → Delete) — removed immediately.
- [ ] Switch between two saved hosts (tap one → use → Disconnect → tap the other).

---

## 9. Build / deploy notes

- `flutter test` (219) + `flutter analyze` are green; `go test ./...` green.
- **Android debug APK: VERIFIED building** — `flutter build apk --debug` →
  `√ Built build/app/outputs/flutter-apk/app-debug.apk`.
  - Required a one-line fix in `app/android/gradle.properties`:
    `kotlin.incremental=false`. Without it the build fails with
    `:share_plus:compileDebugKotlin > Could not close incremental caches`
    (Kotlin incremental compiler failing to close its `.tab` caches on Windows).
  - Non-fatal warning: `share_plus` still applies the Kotlin Gradle Plugin; a
    future Flutter will require Built-in Kotlin. Upgrade `share_plus` when its
    author ships a Built-in-Kotlin version. Not blocking today.
  - To install on a device/emulator: accept SDK licenses once
    (`flutter doctor --android-licenses`), then `flutter run` (debug).
- **iOS:** requires a Mac with Xcode; not buildable from this Windows host.
