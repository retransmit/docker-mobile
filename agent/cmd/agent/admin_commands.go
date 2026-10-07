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
	readOnly := fs.Bool("read-only", false, "pair a phone that may look but not change anything")
	// The word in back quotes is what the help shows as the flag's value.
	name := fs.String("name", "", "`NAME` for the phone (default: what the phone calls itself)")
	host := fs.String("host", "", "`ADDR` at which phones reach this agent, host or host:port")
	invert := fs.Bool("invert", false, "draw the QR code for a light terminal")
	noQR := fs.Bool("no-qr", false, "do not draw the QR code")
	if done, err := parseArgs(fs, args, "pair [--read-only] [--name NAME] [--host ADDR] [--invert] [--no-qr]", stdout); done || err != nil {
		return err
	}
	req := admin.PairRequest{Name: *name, Host: *host}
	if *readOnly {
		req.Role = "readonly"
	}
	ctx, stop := signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)
	defer stop()

	var (
		end   *admin.Event // the event that ended the pairing; nil for as long as none has
		shown bool         // whether a code has been shown
	)
	err := admin.NewClient(config.DataDir(getenv)).Pair(ctx, req, func(e admin.Event) {
		if e.Event != admin.EventStarted {
			end = &e
			return
		}
		shown = true
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
	said, err := pairEnding(end, err, shown)
	fmt.Fprint(stdout, said)
	return err
}

// pairEnding decides what the pair command says once the pairing is over for
// it: what goes to standard output, and the error the command ends with. A
// nil error is exit status 0. Any other is printed to standard error by the
// caller and is exit status 1.
//
// end is the event that ended the pairing, nil when the command saw none.
// err is what the client returned. shown says whether the command had shown
// a code.
func pairEnding(end *admin.Event, err error, shown bool) (stdout string, failure error) {
	if end == nil {
		interrupted := errors.Is(err, context.Canceled)
		stopped := err == nil || errors.Is(err, admin.ErrStopped)
		if !interrupted && !stopped {
			return "", err
		}
		if !shown {
			// Nobody has seen a code: there is none to speak of, and no
			// phone that could have used one.
			if interrupted {
				return "", errors.New("pairing cancelled before a code was shown")
			}
			return "", admin.ErrStopped
		}
		// A code was shown, and the pairing did not end where this command
		// could see it: the command does not know whether a phone was
		// paired. The agent uses the code up and stores the device before it
		// answers the phone, so a phone can have paired in the very moment
		// the command was interrupted or the agent stopped.
		if interrupted {
			return "", errors.New(`pairing cancelled; the code no longer works. If a phone used it in the same moment it is paired: check with "docker-mobile-agent devices"`)
		}
		return "", fmt.Errorf(`%w; the code no longer works. If a phone used it in the same moment it is paired, and still is when the agent runs again: check then with "docker-mobile-agent devices"`, admin.ErrStopped)
	}
	// How the pairing ended is reported whatever err says: a phone that was
	// paired is paired, also when the command was interrupted just then.
	switch end.Event {
	case "paired":
		if end.Device == nil {
			return "", errors.New(`the agent says a phone was paired, but not which one: look at "docker-mobile-agent devices"`)
		}
		return fmt.Sprintf("Paired: %s (id %s, %s)\n", end.Device.Name, end.Device.ID, accessLabel(end.Device.Role)), nil
	case "expired":
		return "", errors.New("the code expired before a phone used it; run pair again")
	case "replaced":
		return "", errors.New("another pair command replaced this code")
	case "voided":
		return "", errors.New("too many wrong attempts: the code was voided; run pair again")
	case "failed":
		return "", fmt.Errorf("the phone proved the code but the agent could not store it: %s", end.Error)
	default:
		return "", fmt.Errorf("pairing ended as %q", end.Event)
	}
}

func cmdDevices(ctx context.Context, args []string, getenv func(string) string, stdout io.Writer) error {
	if done, err := parseArgs(flag.NewFlagSet("devices", flag.ContinueOnError), args, "devices", stdout); done || err != nil {
		return err
	}
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
	fs := flag.NewFlagSet("revoke", flag.ContinueOnError)
	if done, err := parseFlags(fs, args, "revoke ID", stdout); done || err != nil {
		return err
	}
	if fs.NArg() != 1 || fs.Arg(0) == "" {
		return errors.New("revoke: give the id of one device (see: docker-mobile-agent devices)")
	}
	dev, closed, err := admin.NewClient(config.DataDir(getenv)).Revoke(ctx, fs.Arg(0))
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "Revoked %s (id %s); closed %d open connection(s).\n", dev.Name, dev.ID, closed)
	return nil
}
