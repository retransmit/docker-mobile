// Package exec bridges Docker's hijacked exec stream to a WebSocket.
package exec

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"strconv"
	"strings"

	"github.com/0xLennox07/docker-mobile/agent/internal/dockerhost"
)

// startExecHijack dials the Docker daemon and starts the given exec with a TTY,
// hijacking the connection into a raw bidirectional stream.
func startExecHijack(ctx context.Context, dial dockerhost.DialFunc, execID string) (net.Conn, error) {
	conn, err := dial(ctx, "tcp", "docker")
	if err != nil {
		return nil, fmt.Errorf("dial docker: %w", err)
	}
	const body = `{"Detach":false,"Tty":true}`
	req := "POST /exec/" + execID + "/start HTTP/1.1\r\n" +
		"Host: docker\r\n" +
		"Content-Type: application/json\r\n" +
		"Connection: Upgrade\r\n" +
		"Upgrade: tcp\r\n" +
		"Content-Length: " + strconv.Itoa(len(body)) + "\r\n" +
		"\r\n" + body
	if _, err := io.WriteString(conn, req); err != nil {
		conn.Close()
		return nil, fmt.Errorf("write exec start: %w", err)
	}

	br := bufio.NewReader(conn)
	statusLine, err := br.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("read status line: %w", err)
	}
	fields := strings.SplitN(strings.TrimSpace(statusLine), " ", 3)
	if len(fields) < 2 {
		conn.Close()
		return nil, fmt.Errorf("malformed status line: %q", statusLine)
	}
	code, err := strconv.Atoi(fields[1])
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("bad status code %q", fields[1])
	}
	if code != 101 && code != 200 {
		conn.Close()
		return nil, fmt.Errorf("exec start: unexpected status %d", code)
	}
	// Drain the remaining response headers up to the blank line.
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			conn.Close()
			return nil, fmt.Errorf("read headers: %w", err)
		}
		if line == "\r\n" || line == "\n" {
			break
		}
	}
	// br may already hold stream bytes read past the headers.
	return &bufferedConn{Conn: conn, r: br}, nil
}

// bufferedConn makes reads drain any bytes the header parser buffered first.
type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(p []byte) (int, error) { return c.r.Read(p) }
