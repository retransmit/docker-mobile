# docker-mobile

Open-source, self-hostable mobile app (Flutter, iOS + Android) for full control of
Docker from your phone.

## Layout
- `agent/` - Go companion agent: authenticated transparent proxy to the Docker socket.
- `app/`   - Flutter app.

## Run the agent (dev)
The agent serves TLS with a certificate of its own and keeps its state (key,
certificate, paired phones) in a folder:
```
cd agent
AGENT_DATA=./.agent-data go run ./cmd/agent
```
It listens on `:8443`. On Docker Desktop point it at the exposed TCP API with
`DOCKER_HOST=tcp://127.0.0.1:2375`.

The app in this repository does not yet connect to that certificate. Until it does,
run the agent the way the app expects, over plain HTTP with a shared token of at
least 16 characters:
```
AGENT_DATA=./.agent-data AGENT_TOKEN=replace-me-with-32-or-more-characters go run ./cmd/agent --insecure-http
```
That listens on `:8080`. `go run ./cmd/agent help` lists every command and setting.

Pair a phone with the running agent, then list or remove paired phones:
```
AGENT_DATA=./.agent-data go run ./cmd/agent pair
AGENT_DATA=./.agent-data go run ./cmd/agent devices
AGENT_DATA=./.agent-data go run ./cmd/agent revoke <id>
```

`pair --read-only` pairs a phone that can change nothing. It can read the
lists, the logs and the full inspect output of containers, which includes
their environment variables. Two consequences when the agent itself runs
in a container:

- Do not give the agent `AGENT_TOKEN` through its container's environment.
  A read-only phone could read it there, and that token gives full
  control. Pair phones instead.
- Run `pair` inside the running agent's container, never as the main
  process of a container of its own:
  ```
  docker exec -it <agent container> docker-mobile-agent pair
  ```
  A container's main process writes to that container's log, and the
  pairing code would be readable there for as long as it is valid.

### Coming from an earlier version of the agent

- The agent serves TLS with its own certificate on port 8443 by default.
  The app in this repository cannot use that yet: start the agent with
  `--insecure-http` (plain HTTP on port 8080, as before) until it can.
- `AGENT_TOKEN` is optional now. When it is set it must be at least 16
  characters, with no spaces around it; the old example value
  `dev-secret` is refused.
- The agent keeps a state folder (`AGENT_DATA`, by default
  `/var/lib/docker-mobile-agent`), also in plain HTTP mode. It must belong
  to the user the agent runs as and hold nothing else. One agent uses one
  folder, and `pair`, `devices` and `revoke` need the same user and the
  same `AGENT_DATA`.
- Ten wrong tokens or pairing attempts within ten minutes from one address
  block that address for 1 to 15 minutes. Behind a reverse proxy every
  client shares the proxy's address.
- Requests with an `Origin` header are refused, request bodies are limited
  to 16 MiB except for builds, image loads and uploads into a container,
  and errors are answered as JSON.
- Stopping the agent can take up to five seconds while open streams are
  ended.

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
