package proxy

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// fakeDaemon emulates the bits of the Docker API this test needs.
func fakeDaemon() *httptest.Server {
	mux := http.NewServeMux()
	mux.HandleFunc("/_ping", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Api-Version", "1.45")
		w.Write([]byte("OK"))
	})
	mux.HandleFunc("/containers/json", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode([]map[string]any{
			{"Id": "abc123", "Names": []string{"/web"}, "Image": "nginx", "State": "running", "Status": "Up 2 hours"},
		})
	})
	return httptest.NewServer(mux)
}

func TestProxyForwardsJSON(t *testing.T) {
	daemon := fakeDaemon()
	defer daemon.Close()

	h, err := New("tcp://" + daemon.Listener.Addr().String())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	rec := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/containers/json?all=true", nil)
	h.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("code = %d, want 200", rec.Code)
	}
	body, _ := io.ReadAll(rec.Body)
	var got []map[string]any
	if err := json.Unmarshal(body, &got); err != nil {
		t.Fatalf("decode: %v (body=%s)", err, body)
	}
	if len(got) != 1 || got[0]["Id"] != "abc123" {
		t.Fatalf("unexpected body: %s", body)
	}
}

func TestProxyForwardsPing(t *testing.T) {
	daemon := fakeDaemon()
	defer daemon.Close()
	h, _ := New("tcp://" + daemon.Listener.Addr().String())
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/_ping", nil))
	if rec.Code != http.StatusOK || rec.Header().Get("Api-Version") != "1.45" {
		t.Fatalf("ping not proxied: code=%d apiver=%q", rec.Code, rec.Header().Get("Api-Version"))
	}
}
