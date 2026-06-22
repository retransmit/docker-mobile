// Package exec bridges Docker's hijacked exec stream to a WebSocket.
package exec

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/0xLennox07/docker-mobile/agent/internal/dockerhost"
	"github.com/gorilla/websocket"
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

// NewHandler returns a handler that upgrades the request to a WebSocket and
// bridges it to a hijacked exec stream on the daemon at dockerHost.
func NewHandler(dockerHost string) (http.Handler, error) {
	dial, _, err := dockerhost.DialContextFor(dockerHost)
	if err != nil {
		return nil, err
	}
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		execID := r.PathValue("id")
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return // Upgrade already wrote an error response
		}
		defer ws.Close()
		conn, err := startExecHijack(r.Context(), dial, execID)
		if err != nil {
			ws.WriteControl(
				websocket.CloseMessage,
				websocket.FormatCloseMessage(websocket.CloseInternalServerErr, "exec start failed"),
				time.Now().Add(time.Second),
			)
			return
		}
		defer conn.Close()
		bridge(ws, conn)
	}), nil
}

// bridge copies bytes between the WebSocket (stdin) and the conn (stdout) until
// either side ends, then tears down both directions.
func bridge(ws *websocket.Conn, conn net.Conn) {
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 32*1024)
		for {
			n, err := conn.Read(buf)
			if n > 0 {
				if werr := ws.WriteMessage(websocket.BinaryMessage, buf[:n]); werr != nil {
					break
				}
			}
			if err != nil {
				break
			}
		}
		ws.Close() // unblock the reader below
	}()
	for {
		_, data, err := ws.ReadMessage()
		if err != nil {
			break
		}
		if _, werr := conn.Write(data); werr != nil {
			break
		}
	}
	conn.Close()
	<-done
}
