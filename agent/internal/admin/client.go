package admin

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"path/filepath"
)

// ErrNotRunning means nothing answers on the admin socket.
var ErrNotRunning = errors.New("the agent is not running on this state folder")

// ErrStopped means the agent went away while a pairing was pending.
var ErrStopped = errors.New("the agent stopped before the pairing ended")

// Client talks to a running agent through its admin socket.
type Client struct {
	http *http.Client
}

// NewClient returns a client for the agent whose state folder is dataDir.
// It does not create the folder.
func NewClient(dataDir string) *Client {
	path := filepath.Join(dataDir, socketName)
	return &Client{http: &http.Client{Transport: &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			var d net.Dialer
			return d.DialContext(ctx, "unix", path)
		},
	}}}
}

func (c *Client) do(ctx context.Context, method, path string, body any) (*http.Response, error) {
	var reader io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		reader = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://agent"+path, reader)
	if err != nil {
		return nil, err
	}
	resp, err := c.http.Do(req)
	if err != nil {
		var opErr *net.OpError
		if errors.As(err, &opErr) && opErr.Op == "dial" {
			return nil, ErrNotRunning
		}
		return nil, err
	}
	if resp.StatusCode >= 400 {
		defer resp.Body.Close()
		var e errorResponse
		if json.NewDecoder(resp.Body).Decode(&e) == nil && e.Message != "" {
			return nil, errors.New(e.Message)
		}
		return nil, fmt.Errorf("the agent answered %s", resp.Status)
	}
	return resp, nil
}

// Pair starts a pairing and calls onEvent for the "started" event and then
// for the one that ends it. It returns when the pairing is over. Cancelling
// ctx cancels the pairing.
func (c *Client) Pair(ctx context.Context, req PairRequest, onEvent func(Event)) error {
	resp, err := c.do(ctx, http.MethodPost, "/pair", req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	lines := bufio.NewScanner(resp.Body)
	last := ""
	for lines.Scan() {
		var e Event
		if err := json.Unmarshal(lines.Bytes(), &e); err != nil {
			return fmt.Errorf("unreadable answer from the agent: %w", err)
		}
		last = e.Event
		onEvent(e)
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	if last == "" || last == EventStarted {
		// The stream broke off without an ending event.
		return ErrStopped
	}
	return lines.Err()
}

// Devices lists the paired devices, oldest first.
func (c *Client) Devices(ctx context.Context) ([]DeviceInfo, error) {
	resp, err := c.do(ctx, http.MethodGet, "/devices", nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	var out devicesResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("unreadable answer from the agent: %w", err)
	}
	return out.Devices, nil
}

// Revoke removes a device and reports how many of its requests were closed.
func (c *Client) Revoke(ctx context.Context, id string) (DeviceInfo, int, error) {
	resp, err := c.do(ctx, http.MethodDelete, "/devices/"+url.PathEscape(id), nil)
	if err != nil {
		return DeviceInfo{}, 0, err
	}
	defer resp.Body.Close()
	var out revokeResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return DeviceInfo{}, 0, fmt.Errorf("unreadable answer from the agent: %w", err)
	}
	return out.Device, out.Closed, nil
}
