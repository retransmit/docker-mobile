// Command agent runs the docker-mobile companion agent and manages the
// phones paired with it.
package main

import (
	"context"
	"fmt"
	"io"
	"os"
	"strings"
)

// version is set at build time with -ldflags "-X main.version=...".
var version = "dev"

const usage = `docker-mobile-agent - lets the docker-mobile app control this Docker host

Usage:
  docker-mobile-agent [serve] [--insecure-http]   run the agent (default)
  docker-mobile-agent pair [--read-only] [--name NAME] [--host ADDR] [--invert] [--no-qr]
                                                  pair a phone with the running agent
  docker-mobile-agent devices                     list paired phones
  docker-mobile-agent revoke ID                   remove a paired phone
  docker-mobile-agent fingerprint                 print the certificate fingerprint
  docker-mobile-agent healthcheck [--insecure-http]
                                                  exit 0 when the agent answers
  docker-mobile-agent version                     print the version

Environment:
  AGENT_LISTEN          listen address (default :8443, or :8080 with --insecure-http)
  AGENT_DATA            state folder (default /var/lib/docker-mobile-agent)
  AGENT_ADVERTISE       address phones reach the agent at, for pairing codes
  AGENT_NAME            name shown on the phone while pairing (default: host name)
  AGENT_INSECURE_HTTP   1 = serve plain HTTP, behind a proxy that terminates TLS
  AGENT_TOKEN           shared token of older setups (at least 16 characters)
  DOCKER_HOST           Docker daemon (default unix:///var/run/docker.sock)
`

func main() {
	os.Exit(run(context.Background(), os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}

// run executes one command and returns the process exit code.
func run(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	cmd, rest := "serve", args
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") {
		cmd, rest = args[0], args[1:]
	}
	var err error
	switch cmd {
	case "serve":
		err = cmdServe(ctx, rest, getenv, stderr)
	case "pair":
		err = cmdPair(ctx, rest, getenv, stdout)
	case "devices":
		err = cmdDevices(ctx, getenv, stdout)
	case "revoke":
		err = cmdRevoke(ctx, rest, getenv, stdout)
	case "fingerprint":
		err = cmdFingerprint(getenv, stdout)
	case "healthcheck":
		err = cmdHealthcheck(ctx, rest, getenv)
	case "version":
		fmt.Fprintln(stdout, versionLine())
	case "help":
		fmt.Fprint(stdout, usage)
	default:
		fmt.Fprintf(stderr, "docker-mobile-agent: unknown command %q\n\n%s", cmd, usage)
		return 2
	}
	if err != nil {
		fmt.Fprintln(stderr, "docker-mobile-agent:", err)
		return 1
	}
	return 0
}
