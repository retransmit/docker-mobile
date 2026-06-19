# docker-mobile

Open-source, self-hostable mobile app (Flutter, iOS + Android) for full control of
Docker from your phone. See `docs/superpowers/specs/` for the design.

## Layout
- `agent/` — Go companion agent: authenticated transparent proxy to the Docker socket.
- `app/`   — Flutter app.

## Run the agent (dev)
```
cd agent
AGENT_TOKEN=dev-secret DOCKER_HOST=unix:///var/run/docker.sock go run ./cmd/agent
```
The agent listens on `:8080` by default. On Docker Desktop you can instead point it at
the exposed TCP API, e.g. `DOCKER_HOST=tcp://127.0.0.1:2375`.

## Run the app (dev)
```
cd app
flutter run
```
Enter the agent's host, port, and token on the connection screen.

## Test
```
cd agent && go test ./...
cd app && flutter test
```
