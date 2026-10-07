// Command agent runs the docker-mobile companion agent and manages the
// phones paired with it.
package main

import (
	"context"
	"errors"
	"flag"
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
  docker-mobile-agent help                        show this text

Every command shows its flags with --help.

Environment:
  AGENT_LISTEN          listen address (default :8443, or :8080 with --insecure-http)
  AGENT_DATA            state folder (default /var/lib/docker-mobile-agent)
  AGENT_ADVERTISE       address phones reach the agent at, for pairing codes
  AGENT_NAME            name shown on the phone while pairing (default: host name)
  AGENT_INSECURE_HTTP   1, true, yes or on: serve plain HTTP, behind a proxy that
                        terminates TLS (the same as --insecure-http); 0, false,
                        no, off or not set: no effect; any other value is an error
  AGENT_TOKEN           shared token of older setups (at least 16 characters)
  DOCKER_HOST           Docker daemon (default unix:///var/run/docker.sock)
`

func main() {
	os.Exit(run(context.Background(), os.Args[1:], os.Getenv, os.Stdout, os.Stderr))
}

// run executes one command and returns the process exit code.
func run(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer) int {
	// Without a command the agent serves, and what is given are the flags of
	// serve. Help asked for in that place is the help for all of it.
	cmd, rest := "serve", args
	if len(args) > 0 {
		switch {
		case isHelpFlag(args[0]):
			cmd, rest = "help", args[1:]
		case !strings.HasPrefix(args[0], "-"):
			cmd, rest = args[0], args[1:]
		}
	}
	var err error
	switch cmd {
	case "serve":
		err = cmdServe(ctx, rest, getenv, stdout, stderr)
	case "pair":
		err = cmdPair(ctx, rest, getenv, stdout)
	case "devices":
		err = cmdDevices(ctx, rest, getenv, stdout)
	case "revoke":
		err = cmdRevoke(ctx, rest, getenv, stdout)
	case "fingerprint":
		err = cmdFingerprint(rest, getenv, stdout)
	case "healthcheck":
		err = cmdHealthcheck(ctx, rest, getenv, stdout)
	case "version":
		err = cmdVersion(rest, stdout)
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

// isHelpFlag reports whether arg is one of the spellings the flag package
// takes for a request for help.
func isHelpFlag(arg string) bool {
	switch arg {
	case "-h", "--h", "-help", "--help":
		return true
	}
	return false
}

// parseFlags reads the flags of one command from args. synopsis is how the
// command is called, as the usage text has it. When the arguments ask for
// help, the command's own help goes to stdout and done is true: the command
// has nothing left to do. What follows the flags stays in fs.Args for the
// caller.
//
// The help is all that is ever written here. The flag package would print
// every mistake itself, with the list of flags after it; the mistake comes
// back as the error instead, and whoever called the command prints it once.
func parseFlags(fs *flag.FlagSet, args []string, synopsis string, stdout io.Writer) (done bool, err error) {
	fs.SetOutput(io.Discard)
	err = fs.Parse(args)
	if errors.Is(err, flag.ErrHelp) {
		fmt.Fprintf(stdout, "Usage: docker-mobile-agent %s\n", synopsis)
		first := true
		fs.VisitAll(func(f *flag.Flag) {
			if first {
				fmt.Fprint(stdout, "\nFlags:\n")
				first = false
			}
			value, about := flag.UnquoteUsage(f)
			if value != "" {
				value = " " + value
			}
			fmt.Fprintf(stdout, "  --%s%s\n        %s\n", f.Name, value, about)
		})
		return true, nil
	}
	if err != nil {
		return false, fmt.Errorf("%s: %v (see: docker-mobile-agent %s --help)", fs.Name(), err, fs.Name())
	}
	return false, nil
}

// parseArgs is parseFlags for a command that takes nothing besides flags:
// anything else on its command line is refused.
func parseArgs(fs *flag.FlagSet, args []string, synopsis string, stdout io.Writer) (done bool, err error) {
	if done, err := parseFlags(fs, args, synopsis, stdout); done || err != nil {
		return done, err
	}
	if fs.NArg() > 0 {
		return false, fmt.Errorf("%s: unexpected argument %q (see: docker-mobile-agent %s --help)", fs.Name(), fs.Arg(0), fs.Name())
	}
	return false, nil
}
