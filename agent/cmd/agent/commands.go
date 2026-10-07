package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"runtime"
	"runtime/debug"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/config"
	"github.com/retransmit/docker-mobile/agent/internal/tlsid"
)

func cmdFingerprint(getenv func(string) string, stdout io.Writer) error {
	dataDir := config.DataDir(getenv)
	fp, err := tlsid.ReadFingerprint(dataDir)
	if errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("no certificate in %s: the agent has not run yet, or it runs with --insecure-http", dataDir)
	}
	if err != nil {
		return err
	}
	fmt.Fprintln(stdout, fp.Display())
	return nil
}

// cmdHealthcheck asks the agent on this machine for /healthz. Over TLS it
// trusts exactly the certificate in the state folder.
func cmdHealthcheck(ctx context.Context, args []string, getenv func(string) string) error {
	fs := flag.NewFlagSet("healthcheck", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	insecure := fs.Bool("insecure-http", false, "the agent serves plain HTTP")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("healthcheck: %v", err)
	}
	cfg, err := config.Load(getenv, *insecure)
	if err != nil {
		return err
	}
	host, port, err := net.SplitHostPort(cfg.ListenAddr)
	if err != nil {
		return err
	}
	if ip := net.ParseIP(host); host == "" || (ip != nil && ip.IsUnspecified()) {
		host = "127.0.0.1"
	}
	scheme := "http"
	transport := &http.Transport{}
	if !cfg.InsecureHTTP {
		scheme = "https"
		transport.TLSClientConfig, err = tlsid.LocalClientConfig(cfg.DataDir)
		if err != nil {
			return fmt.Errorf("read the agent's certificate: %w", err)
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, scheme+"://"+net.JoinHostPort(host, port)+"/healthz", nil)
	if err != nil {
		return err
	}
	resp, err := (&http.Client{Transport: transport}).Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("the agent answered %s", resp.Status)
	}
	return nil
}

func versionLine() string {
	commit, built := "unknown", "unknown"
	if info, ok := debug.ReadBuildInfo(); ok {
		for _, s := range info.Settings {
			switch s.Key {
			case "vcs.revision":
				commit = s.Value
				if len(commit) > 12 {
					commit = commit[:12]
				}
			case "vcs.time":
				built = s.Value
			}
		}
	}
	return fmt.Sprintf("docker-mobile-agent %s (commit %s, built %s, %s)", version, commit, built, runtime.Version())
}
