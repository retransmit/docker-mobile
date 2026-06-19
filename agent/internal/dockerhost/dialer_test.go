package dockerhost

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDialContextForTCP(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("pong"))
	}))
	defer srv.Close()

	dial, base, err := DialContextFor("tcp://" + srv.Listener.Addr().String())
	if err != nil {
		t.Fatalf("DialContextFor: %v", err)
	}
	if base != "http://"+srv.Listener.Addr().String() {
		t.Errorf("base = %q", base)
	}
	// The dial function must reach the test server regardless of the addr passed.
	conn, err := dial(context.Background(), "tcp", "ignored:0")
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	_ = conn.Close()
}

func TestDialContextForUnixBaseURL(t *testing.T) {
	dial, base, err := DialContextFor("unix:///var/run/docker.sock")
	if err != nil {
		t.Fatalf("DialContextFor: %v", err)
	}
	if base != "http://docker" {
		t.Errorf("base = %q, want http://docker", base)
	}
	if dial == nil {
		t.Fatal("dial is nil")
	}
}

func TestDialContextForUnknownScheme(t *testing.T) {
	if _, _, err := DialContextFor("ssh://host"); err == nil {
		t.Fatal("expected error for unsupported scheme")
	}
}
