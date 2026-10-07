package main

import (
	"bytes"
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
	"strings"
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

// serverLog hands what net/http reports to the agent's log, except failed
// TLS handshakes: on an open port those are mostly scanners.
type serverLog struct{ log *slog.Logger }

func (w serverLog) Write(p []byte) (int, error) {
	if !bytes.HasPrefix(p, []byte("http: TLS handshake error")) {
		w.log.Error(strings.TrimSpace(string(p)))
	}
	return len(p), nil
}

func cmdServe(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer) error {
	fs := flag.NewFlagSet("serve", flag.ContinueOnError)
	insecure := fs.Bool("insecure-http", false, "serve plain HTTP, behind a proxy that terminates TLS")
	if done, err := parseArgs(fs, args, "[serve] [--insecure-http]", stdout); done || err != nil {
		return err
	}
	cfg, err := config.Load(getenv, *insecure)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()
	// Once the agent has been told to stop, the signals get their default
	// behaviour back: a second interrupt ends the process at once instead of
	// being swallowed while the first one is still being acted on.
	context.AfterFunc(ctx, stop)
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
	// However this function ends, the socket is removed and the folder given
	// up. On the ordinary way out the admin server has closed the listener
	// before; closing it a second time does nothing.
	defer adminLn.Close()
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

	// What net/http has to report, such as the panic of a handler or an
	// accept that fails, goes to the agent's log. The logger adds nothing in
	// front of a report: serverLog tells failed handshakes by how they start.
	errorLog := log.New(serverLog{logger}, "", 0)
	srv := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
		MaxHeaderBytes:    64 << 10,
		ErrorLog:          errorLog,
	}
	// Requests on the admin socket end when the agent begins to stop. The
	// socket itself stays to the end, and with it the lock on the folder.
	adminCtx, endAdminRequests := context.WithCancel(context.Background())
	defer endAdminRequests()
	adminSrv := &http.Server{
		Handler:           adminServer.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
		ErrorLog:          errorLog,
		BaseContext:       func(net.Listener) context.Context { return adminCtx },
	}

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
			// The length itself stays out of the log: the authentication
			// takes care that it cannot be learned from outside.
			logger.Warn("AGENT_TOKEN is short; use at least 32 characters")
		}
	}
	if cfg.LegacyToken == "" && len(devices.List()) == 0 {
		logger.Info("no phone is paired yet; run: docker-mobile-agent pair")
	}

	errc := make(chan error, 2)
	go func() { errc <- srv.Serve(ln) }()
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
	// A pair command that is waiting ends now and not after the grace: no
	// phone could use its code any more. One that starts from here on ends
	// at once for the same reason.
	endAdminRequests()
	grace, cancel := context.WithTimeout(context.Background(), shutdownGrace)
	defer cancel()
	// Stop accepting and let short requests finish. Streams and terminals
	// never finish by themselves: once the grace is over, end them so that
	// clients see the connection close instead of hanging.
	shutdownErr := srv.Shutdown(grace)
	registry.CloseAll()
	// What fails on the way out is reported, unless it only says that the
	// thing was closed already.
	report := func(what string, err error) {
		if err != nil && !errors.Is(err, net.ErrClosed) {
			logger.Warn(what, "error", err)
		}
	}
	report("stopping: closing the server failed", srv.Close())
	// The admin socket goes last: closing it gives up the lock on the state
	// folder, and until here a request could still write there.
	report("stopping: closing the admin socket failed", adminSrv.Close())
	if serveErr != nil && !errors.Is(serveErr, http.ErrServerClosed) {
		return serveErr
	}
	if shutdownErr != nil && !errors.Is(shutdownErr, context.DeadlineExceeded) {
		return shutdownErr
	}
	return nil
}
