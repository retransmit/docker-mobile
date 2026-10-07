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
AGENT_DATA=./.agent-data AGENT_TOKEN=dev-secret-0123456789 go run ./cmd/agent --insecure-http
```
That listens on `:8080`. `go run ./cmd/agent help` lists every command and setting.

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
