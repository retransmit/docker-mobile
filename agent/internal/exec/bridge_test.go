package exec

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/0xLennox07/docker-mobile/agent/internal/auth"
	"github.com/gorilla/websocket"
)

// fakeExecStart serves one connection: records the request, replies with
// `response`, then (optionally) keeps the connection for streaming.
func fakeExecStart(t *testing.T, response string, gotReq *string, hold chan struct{}) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		br := bufio.NewReader(conn)
		req, err := http.ReadRequest(br)
		if err != nil {
			return
		}
		body, _ := io.ReadAll(req.Body)
		*gotReq = req.Method + " " + req.URL.Path + "|" + string(body)
		io.WriteString(conn, response)
		if hold != nil {
			<-hold
		}
	}()
	return ln.Addr().String()
}

func dialTo(addr string) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, _, _ string) (net.Conn, error) { return net.Dial("tcp", addr) }
}

func TestStartExecHijackReturnsRawStream(t *testing.T) {
	var got string
	addr := fakeExecStart(t, "HTTP/1.1 101 UPGRADED\r\n\r\nHELLO", &got, nil)

	conn, err := startExecHijack(context.Background(), dialTo(addr), "abc")
	if err != nil {
		t.Fatalf("startExecHijack: %v", err)
	}
	defer conn.Close()

	if !strings.Contains(got, "POST /exec/abc/start") {
		t.Errorf("request line = %q", got)
	}
	if !strings.Contains(got, `"Tty":true`) {
		t.Errorf("request body = %q", got)
	}
	buf := make([]byte, 5)
	if _, err := io.ReadFull(conn, buf); err != nil {
		t.Fatalf("read stream: %v", err)
	}
	if string(buf) != "HELLO" {
		t.Errorf("stream = %q, want HELLO", buf)
	}
}

func TestStartExecHijackRejectsErrorStatus(t *testing.T) {
	var got string
	addr := fakeExecStart(t, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n", &got, nil)
	if _, err := startExecHijack(context.Background(), dialTo(addr), "abc"); err == nil {
		t.Fatal("expected error on 500 status")
	}
}

func TestExecBridgeEchoesBothDirections(t *testing.T) {
	// Fake daemon: parse the exec-start request, reply 101, then echo stdin->stdout.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		br := bufio.NewReader(conn)
		req, err := http.ReadRequest(br)
		if err != nil {
			return
		}
		io.ReadAll(req.Body)
		io.WriteString(conn, "HTTP/1.1 101 UPGRADED\r\n\r\n")
		io.Copy(conn, br) // echo stdin back as stdout
	}()

	h, err := NewHandler("tcp://" + ln.Addr().String())
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	mux := http.NewServeMux()
	mux.Handle("GET /exec/{id}/ws", auth.RequireToken("secret", h))
	srv := httptest.NewServer(mux)
	defer srv.Close()
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/exec/abc/ws"

	// Without a token -> rejected at the auth layer.
	if _, resp, err := websocket.DefaultDialer.Dial(wsURL, nil); err == nil {
		t.Fatal("expected auth rejection")
	} else if resp == nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("want 401, got %v", resp)
	}

	// With a token -> connect and echo.
	c, _, err := websocket.DefaultDialer.Dial(wsURL, http.Header{"Authorization": {"Bearer secret"}})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()
	if err := c.WriteMessage(websocket.BinaryMessage, []byte("hello")); err != nil {
		t.Fatalf("write: %v", err)
	}
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	_, data, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if string(data) != "hello" {
		t.Fatalf("echo = %q, want hello", data)
	}
}
