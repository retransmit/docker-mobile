package server

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/0xLennox07/docker-mobile/agent/internal/config"
)

func fakeDaemon() *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode([]map[string]any{{"Id": "x"}})
	}))
}

func newHandler(t *testing.T, daemon *httptest.Server) http.Handler {
	t.Helper()
	h, err := Handler(config.Config{
		ListenAddr: ":0",
		Token:      "secret",
		DockerHost: "tcp://" + daemon.Listener.Addr().String(),
	})
	if err != nil {
		t.Fatalf("Handler: %v", err)
	}
	return h
}

func TestHealthzNoAuth(t *testing.T) {
	d := fakeDaemon()
	defer d.Close()
	h := newHandler(t, d)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("healthz code = %d, want 200", rec.Code)
	}
}

func TestProxiedPathRequiresAuth(t *testing.T) {
	d := fakeDaemon()
	defer d.Close()
	h := newHandler(t, d)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/containers/json", nil))
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("unauthenticated proxy code = %d, want 401", rec.Code)
	}
}

func TestProxiedPathWithAuth(t *testing.T) {
	d := fakeDaemon()
	defer d.Close()
	h := newHandler(t, d)
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/containers/json", nil)
	req.Header.Set("Authorization", "Bearer secret")
	h.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("authenticated proxy code = %d, want 200", rec.Code)
	}
}
