package main

import (
	"context"
	"crypto/rand"
	"crypto/tls"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/admin"
	"github.com/retransmit/docker-mobile/agent/internal/config"
	"github.com/retransmit/docker-mobile/agent/internal/conns"
	"github.com/retransmit/docker-mobile/agent/internal/pairing"
	"github.com/retransmit/docker-mobile/agent/internal/server"
	"github.com/retransmit/docker-mobile/agent/internal/state"
	"github.com/retransmit/docker-mobile/agent/internal/throttle"
	"github.com/retransmit/docker-mobile/agent/internal/tlsid"
)

// shutdownGrace is how long requests in flight get to finish when the agent
// stops. After it, streams and terminals are closed. It is a variable so
// that tests can shorten it.
var shutdownGrace = 5 * time.Second

func cmdServe(ctx context.Context, args []string, getenv func(string) string, stderr io.Writer) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	fs.SetOutput(stderr)
	insecure := fs.Bool("insecure-http", false, "serve plain HTTP, behind a proxy that terminates TLS")
	if err := fs.Parse(args); err != nil {
		return err
	}
	cfg, err := config.Load(getenv, *insecure)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	return serve(ctx, cfg, slog.New(slog.NewTextHandler(stderr, nil)), nil)
}

// serve runs the agent until ctx ends. ready, when not nil, is called once
// with the address the agent listens on.
func serve(ctx context.Context, cfg config.Config, logger *slog.Logger, ready func(net.Addr)) error {
	dir, err := state.Open(cfg.DataDir)
	if err != nil {
		return err
	}
	// The admin socket is what keeps a second agent off this folder, so it is
	// taken before anything reads or writes the state: the device list and
	// the certificate below are state.
	adminLn, err := admin.Listen(dir)
	if err != nil {
		return err
	}
	adminServing := false
	defer func() {
		if !adminServing {
			adminLn.Close()
		}
	}()
	devices, err := state.LoadDevices(dir, time.Now)
	if err != nil {
		return err
	}

	var (
		cert        tls.Certificate
		fingerprint []byte
		fpLink      string
		fpDisplay   string
	)
	if !cfg.InsecureHTTP {
		cert, err = tlsid.LoadOrCreate(dir, time.Now())
		if err != nil {
			return err
		}
		fp, err := tlsid.FingerprintOf(cert)
		if err != nil {
			return err
		}
		fingerprint, fpLink, fpDisplay = fp[:], fp.String(), fp.Display()
	}

	name := cfg.Name
	if name == "" {
		name, _ = os.Hostname()
	}
	registry := conns.New()
	manager := pairing.NewManager(time.Now, rand.Reader)
	handler, err := server.New(server.Options{
		DockerHost:  cfg.DockerHost,
		Devices:     devices,
		LegacyToken: cfg.LegacyToken,
		Pairing:     manager,
		Fingerprint: fingerprint,
		Limiter:     throttle.New(time.Now),
		Conns:       registry,
		Version:     version,
		Log:         logger,
	})
	if err != nil {
		return err
	}
	adminServer := &admin.Server{
		Pairing:            manager,
		Devices:            devices,
		Conns:              registry,
		Advertise:          cfg.Advertise,
		Fingerprint:        fpLink,
		FingerprintDisplay: fpDisplay,
		AgentName:          name,
		Log:                logger,
	}

	ln, err := net.Listen("tcp", cfg.ListenAddr)
	if err != nil {
		return fmt.Errorf("listen on %s: %w", cfg.ListenAddr, err)
	}
	if !cfg.InsecureHTTP {
		ln = tls.NewListener(ln, tlsid.ServerConfig(cert))
	}

	// The standard library reports every failed TLS handshake through
	// ErrorLog; on an open port that is mostly scanners, so it is dropped.
	quiet := log.New(io.Discard, "", 0)
	srv := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    64 << 10,
		ErrorLog:          quiet,
	}
	adminSrv := &http.Server{Handler: adminServer.Handler(), ReadHeaderTimeout: 10 * time.Second, ErrorLog: quiet}

	logger.Info("docker-mobile-agent started", "version", version, "listen", ln.Addr().String(), "docker", cfg.DockerHost, "data", cfg.DataDir)
	switch {
	case cfg.InsecureHTTP:
		logger.Warn("serving plain HTTP: nothing is encrypted unless a proxy in front terminates TLS")
	default:
		logger.Info("serving TLS with the agent's own certificate", "fingerprint", fpDisplay)
	}
	if cfg.LegacyToken != "" {
		logger.Info("AGENT_TOKEN is set: it gives full control to whoever holds it; pairing gives each phone its own revocable token")
		if len(cfg.LegacyToken) < config.WeakLegacyToken {
			logger.Warn("AGENT_TOKEN is short; use at least 32 characters", "length", len(cfg.LegacyToken))
		}
	}
	if cfg.LegacyToken == "" && len(devices.List()) == 0 {
		logger.Info("no phone is paired yet; run: docker-mobile-agent pair")
	}

	errc := make(chan error, 2)
	go func() { errc <- srv.Serve(ln) }()
	adminServing = true
	go func() { errc <- adminSrv.Serve(adminLn) }()
	if ready != nil {
		ready(ln.Addr())
	}

	var serveErr error
	select {
	case <-ctx.Done():
	case serveErr = <-errc:
	}

	logger.Info("stopping")
	grace, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	// Stop accepting and let short requests finish. Streams and terminals
	// never finish by themselves: once the grace is over, end them so that
	// clients see the connection close instead of hanging.
	shutdownErr := srv.Shutdown(grace)
	registry.CloseAll()
	srv.Close()
	// The admin socket goes last: closing it gives up the lock on the state
	// folder, and until here a request could still write there. It also ends
	// a pair command that is still waiting.
	adminSrv.Close()
	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		return serveErr
	}
	if shutdownErr != nil && !errors.Is(shutdownErr, context.DeadlineExceeded) {
		return shutdownErr
	}
	return nil
}
