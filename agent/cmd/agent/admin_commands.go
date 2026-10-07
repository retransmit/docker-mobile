package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"
	"text/tabwriter"

	"github.com/retransmit/docker-mobile/agent/internal/admin"
	"github.com/retransmit/docker-mobile/agent/internal/config"
	"github.com/retransmit/docker-mobile/agent/internal/qr"
)

func accessLabel(role string) string {
	if role == "readonly" {
		return "read-only"
	}
	return "full control"
}

func cmdPair(ctx context.Context, args []string, getenv func(string) string, stdout io.Writer) error {
	fs := flag.NewFlagSet("pair", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	readOnly := fs.Bool("read-only", false, "pair a phone that may look but not change anything")
	name := fs.String("name", "", "name for the phone (default: what the phone calls itself)")
	host := fs.String("host", "", "address phones reach this agent at, host or host:port")
	invert := fs.Bool("invert", false, "draw the QR code for a light terminal")
	noQR := fs.Bool("no-qr", false, "do not draw the QR code")
	if err := fs.Parse(args); err != nil {
		return fmt.Errorf("pair: %v", err)
	}
	if fs.NArg() > 0 {
		return fmt.Errorf("pair: unexpected argument %q", fs.Arg(0))
	}
	req := admin.PairRequest{Name: *name, Host: *host}
	if *readOnly {
		req.Role = "readonly"
	}
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	var end admin.Event
	err := admin.NewClient(config.DataDir(getenv)).Pair(ctx, req, func(e admin.Event) {
		if e.Event != admin.EventStarted {
			end = e
			return
		}
		if !*noQR {
			fmt.Fprintln(stdout, "Scan this with the docker-mobile app (Connections, Add, Scan QR code):")
			fmt.Fprintln(stdout)
			if err := qr.Render(stdout, e.Link, *invert); err != nil {
				fmt.Fprintln(stdout, "(the QR code could not be drawn:", err.Error()+")")
			}
			fmt.Fprintln(stdout)
			fmt.Fprintln(stdout, "Or enter it by hand:")
		}
		address := e.Address
		if address == "" {
			address = "(enter this server's address in the app; AGENT_ADVERTISE or --host puts it in the code)"
		}
		fmt.Fprintln(stdout, "  Address:      "+address)
		fmt.Fprintln(stdout, "  Code:         "+e.Code)
		if e.Fingerprint != "" {
			fmt.Fprintln(stdout, "  Fingerprint:  "+e.Fingerprint)
		}
		fmt.Fprintln(stdout, "  Access:       "+accessLabel(e.Role))
		fmt.Fprintln(stdout)
		fmt.Fprintln(stdout, "Or open this link on the phone:")
		fmt.Fprintln(stdout, "  "+e.Link)
		fmt.Fprintln(stdout)
		fmt.Fprintf(stdout, "The code works once and expires in %d minutes. Waiting for the phone (Ctrl-C cancels)...\n", (e.ExpiresIn+59)/60)
	})
	if errors.Is(err, context.Canceled) {
		return errors.New("pairing cancelled; the code no longer works")
	}
	if err != nil {
		return err
	}
	switch end.Event {
	case "paired":
		fmt.Fprintf(stdout, "Paired: %s (id %s, %s)\n", end.Device.Name, end.Device.ID, accessLabel(end.Device.Role))
		return nil
	case "expired":
		return errors.New("the code expired before a phone used it; run pair again")
	case "replaced":
		return errors.New("another pair command replaced this code")
	case "voided":
		return errors.New("too many wrong attempts: the code was voided; run pair again")
	case "failed":
		return fmt.Errorf("the phone proved the code but the agent could not store it: %s", end.Error)
	default:
		return fmt.Errorf("pairing ended as %q", end.Event)
	}
}

func cmdDevices(ctx context.Context, getenv func(string) string, stdout io.Writer) error {
	list, err := admin.NewClient(config.DataDir(getenv)).Devices(ctx)
	if err != nil {
		return err
	}
	if len(list) == 0 {
		fmt.Fprintln(stdout, "No phone is paired. Run: docker-mobile-agent pair")
		return nil
	}
	tw := tabwriter.NewWriter(stdout, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "ID\tNAME\tACCESS\tPAIRED\tLAST SEEN")
	for _, d := range list {
		fmt.Fprintf(tw, "%s\t%s\t%s\t%s\t%s\n", d.ID, d.Name, accessLabel(d.Role),
			d.CreatedAt.Local().Format("2006-01-02 15:04"), d.LastSeenAt.Local().Format("2006-01-02 15:04"))
	}
	return tw.Flush()
}

func cmdRevoke(ctx context.Context, args []string, getenv func(string) string, stdout io.Writer) error {
	if len(args) != 1 || args[0] == "" {
		return errors.New("revoke: give the id of one device (see: docker-mobile-agent devices)")
	}
	dev, closed, err := admin.NewClient(config.DataDir(getenv)).Revoke(ctx, args[0])
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "Revoked %s (id %s); closed %d open connection(s).\n", dev.Name, dev.ID, closed)
	return nil
}
