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
