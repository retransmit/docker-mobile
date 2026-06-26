# Phase 0 — Manual End-to-End Smoke Test

Verifies the full vertical slice against a **real Docker daemon**: the Go agent
proxies the Docker Engine API, and the Flutter app connects and lists containers.
The automated suites (`go test ./...`, `flutter test`) use a simulated daemon and
do **not** require Docker; this manual procedure exercises the real path.

## Prerequisites
- A running Docker daemon.
- Go (to run the agent from source) — or a prebuilt `agent` binary.
- Flutter + an Android emulator / iOS simulator / physical device (for the app).

## 1. Make a Docker daemon reachable by the agent
- **Linux:** the default unix socket works as-is.
- **Docker Desktop (Windows/macOS):** either run the agent in a container that
  mounts the socket, or (dev only) enable
  *Settings → General → "Expose daemon on tcp://localhost:2375 without TLS"* and
  point the agent at that TCP endpoint.

## 2. Run the agent
Linux (unix socket):
```bash
cd agent
AGENT_TOKEN=dev-secret DOCKER_HOST=unix:///var/run/docker.sock go run ./cmd/agent
```
Docker Desktop (TCP):
```bash
cd agent
AGENT_TOKEN=dev-secret DOCKER_HOST=tcp://127.0.0.1:2375 go run ./cmd/agent
```
Expected log: `docker-mobile-agent listening on :8080 (docker host: ...)`

## 3. Verify the agent proxies (curl)
```bash
curl -s http://127.0.0.1:8080/healthz                                  # -> ok
curl -s -H "Authorization: Bearer dev-secret" \
  "http://127.0.0.1:8080/containers/json?all=true"                     # -> JSON array of containers
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://127.0.0.1:8080/containers/json"                              # -> 401 (no token)
```

## 4. Run the app and connect
```bash
cd app
flutter run
```
On the connection screen enter:
- **Host:** from an Android emulator use `10.0.2.2` to reach the host machine; an
  iOS simulator can use `127.0.0.1`; a physical device uses the host's LAN IP.
- **Port:** `8080`
- **Token:** `dev-secret`
- **TLS:** off

Tap **Connect**. Expected: the Containers screen lists the same containers that
`curl` returned in step 3; the refresh icon reloads them.

## Status
Not yet executed end-to-end on a device in this environment (no Android
emulator / iOS simulator installed). Run this procedure once a device or
emulator is available; the agent half has been verified against a simulated
daemon via `go test ./...`.

## TCP+TLS (mTLS) — Phase 1D-1

Real socket + exec hijack path (not covered by unit tests).

1. Generate a CA + server cert + client cert (see Docker's "Protect the Docker daemon socket" guide), then run dockerd with TLS verification:
   `dockerd --tlsverify --tlscacert=ca.pem --tlscert=server-cert.pem --tlskey=server-key.pem -H=0.0.0.0:2376`
2. In the app: Connect → **TCP+TLS**. Enter host, port `2376`, and paste `client-cert.pem`, `client-key.pem`, and `ca.pem` into the CA field. Leave **Allow insecure** OFF.
3. Verify: the container list loads; open a container → **Logs** stream live; **Exec** opens an interactive shell (the hijack path); **System** dashboard loads.
4. Negative check: with a wrong/empty CA and **Allow insecure** OFF, the connection fails the TLS handshake; turning **Allow insecure** ON connects (documented as insecure — MITM-vulnerable).

## SSH (dial-stdio) — Phase 1D-2a

Reach over SSH (the live path; not unit-tested). Requires the `docker` CLI and docker access for the SSH user on the remote.

1. Ensure `ssh user@host docker system dial-stdio` works from a terminal (proves dial-stdio + permissions).
2. From a scratch Dart entrypoint or D2b's form, call `sshDaemonVersion(creds, verifyHostKey: (fp) { print('host key: $fp'); return true; })` with key auth, then password auth.
3. Verify it prints the daemon `/version` JSON. Note the printed fingerprint on first use; a second connect with that fingerprint pinned should return `HostKeyVerdict.match` (wired in D2b).

### Phase 1D-2b — SSH end-to-end via the form

1. Connect → **SSH**. Enter host, port `22`, username; pick **Key** (paste a PEM, optional passphrase) or **Password**.
2. First connect: accept the host key (it is pinned). The container list loads over SSH; open a container → **Logs** stream; **Exec** opens an interactive shell (dial-stdio hijack); **System** loads.
3. Reconnect: the pinned key matches silently.
4. Change the server's host key (or pin a wrong one) and reconnect: the **"Host key changed"** dialog appears; **Cancel** aborts, **Trust new key** re-pins and connects.
