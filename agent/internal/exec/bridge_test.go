package exec

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

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
	mux.Handle("GET /exec/{id}/ws", h)
	srv := httptest.NewServer(mux)
	defer srv.Close()
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/exec/abc/ws"

	c, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
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

func TestEndingTheRequestContextClosesTheTerminal(t *testing.T) {
	// Fake daemon: accept the exec start, reply 101, then stay silent.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	started := make(chan struct{})
	daemonSawEnd := make(chan struct{})
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
		close(started)
		io.Copy(io.Discard, br) // returns when the agent closes its side
		close(daemonSawEnd)
	}()

	h, err := NewHandler("tcp://" + ln.Addr().String())
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		r.SetPathValue("id", "abc")
		h.ServeHTTP(w, r.WithContext(ctx))
	}))
	defer srv.Close()

	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/exec/abc/ws", nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer c.Close()

	select {
	case <-started:
	case <-time.After(3 * time.Second):
		t.Fatal("the exec never started")
	}
	cancel() // the device was removed, or the agent is stopping
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	if _, _, err := c.ReadMessage(); err == nil {
		t.Fatal("the terminal stayed open")
	}
	select {
	case <-daemonSawEnd:
	case <-time.After(3 * time.Second):
		t.Fatal("the connection to the daemon stayed open")
	}
}

func TestStartingATerminalEndsWithItsContext(t *testing.T) {
	// Fake daemon: accept the connection, read the request, then say nothing.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	asked := make(chan struct{})
	over := make(chan struct{})
	defer close(over) // lets the daemon go, which also frees a start that still waits
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		req, err := http.ReadRequest(bufio.NewReader(conn))
		if err != nil {
			return
		}
		io.ReadAll(req.Body)
		close(asked)
		<-over
	}()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	result := make(chan error, 1)
	go func() {
		conn, err := startExecHijack(ctx, dialTo(ln.Addr().String()), "abc")
		if err == nil {
			conn.Close()
		}
		result <- err
	}()

	select {
	case <-asked:
	case <-time.After(3 * time.Second):
		t.Fatal("the daemon never got the request")
	}
	select {
	case err := <-result:
		t.Fatalf("the start returned before the daemon answered: %v", err)
	default:
	}
	cancel() // the device was removed, or the agent is stopping
	select {
	case err := <-result:
		if err == nil {
			t.Fatal("the start succeeded although the daemon never answered")
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the start still waits for the daemon after its context ended")
	}
}

func TestATerminalIDThatIsNoIDIsRefusedBeforeAnythingIsDialled(t *testing.T) {
	// The daemon's side: nobody accepts here, so a connection that was dialled
	// stays queued and is found at the end.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	h, err := NewHandler("tcp://" + ln.Addr().String())
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	mux := http.NewServeMux()
	mux.Handle("GET /exec/{id}/ws", h)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	for name, id := range map[string]string{
		"an encoded CR LF": "abc%0d%0aX-Injected:%20yes",
		"an encoded space": "abc%20def",
		"a letter past f":  "abcg",
		"65 characters":    strings.Repeat("a", 65),
	} {
		c, resp, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/exec/"+id+"/ws", nil)
		if err == nil {
			c.Close()
			t.Errorf("%s: the terminal was opened", name)
			continue
		}
		if resp == nil {
			t.Errorf("%s: no answer: %v", name, err)
			continue
		}
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("%s: code = %d, want 400", name, resp.StatusCode)
			continue
		}
		var body map[string]string
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil || body["message"] == "" {
			t.Errorf("%s: the body is not a JSON message: %v", name, err)
		}
	}

	ln.(*net.TCPListener).SetDeadline(time.Now().Add(100 * time.Millisecond))
	if conn, err := ln.Accept(); err == nil {
		conn.Close()
		t.Fatal("the daemon was dialled for an id that was refused")
	}
}

func TestATerminalIDOf64HexCharactersWorks(t *testing.T) {
	// Fake daemon: report the path it was asked for, reply 101, then echo.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()
	asked := make(chan string, 1)
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
		asked <- req.URL.Path
		io.WriteString(conn, "HTTP/1.1 101 UPGRADED\r\n\r\n")
		io.Copy(conn, br) // echo stdin back as stdout
	}()

	h, err := NewHandler("tcp://" + ln.Addr().String())
	if err != nil {
		t.Fatalf("NewHandler: %v", err)
	}
	mux := http.NewServeMux()
	mux.Handle("GET /exec/{id}/ws", h)
	srv := httptest.NewServer(mux)
	defer srv.Close()

	id := strings.Repeat("0123456789abcdef", 4)
	c, _, err := websocket.DefaultDialer.Dial("ws"+strings.TrimPrefix(srv.URL, "http")+"/exec/"+id+"/ws", nil)
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
	select {
	case path := <-asked:
		if path != "/exec/"+id+"/start" {
			t.Fatalf("the daemon was asked for %q, want /exec/%s/start", path, id)
		}
	default:
		t.Fatal("the daemon was never asked")
	}
}
