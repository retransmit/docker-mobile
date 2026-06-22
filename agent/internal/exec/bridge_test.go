package exec

import (
	"bufio"
	"context"
	"io"
	"net"
	"net/http"
	"strings"
	"testing"
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
