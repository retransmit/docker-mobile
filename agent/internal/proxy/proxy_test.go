package proxy

import (
	"encoding/json"
	"io"
	"net"
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

func TestProxyStreamsIncrementally(t *testing.T) {
	release := make(chan struct{})
	daemon := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fl, ok := w.(http.Flusher)
		if !ok {
			t.Error("ResponseWriter is not a Flusher")
			return
		}
		io.WriteString(w, "first\n")
		fl.Flush()
		<-release // block until the test has read the first chunk
		io.WriteString(w, "second\n")
		fl.Flush()
	}))
	defer daemon.Close()

	h, err := New("tcp://" + daemon.Listener.Addr().String())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	// A real server is needed because httptest.ResponseRecorder does not stream.
	front := httptest.NewServer(h)
	defer front.Close()

	resp, err := http.Get(front.URL + "/containers/x/logs?follow=1")
	if err != nil {
		t.Fatalf("get: %v", err)
	}
	defer resp.Body.Close()

	// The first chunk must arrive BEFORE the handler is released - proving no buffering.
	buf := make([]byte, len("first\n"))
	if _, err := io.ReadFull(resp.Body, buf); err != nil {
		t.Fatalf("read first chunk: %v", err)
	}
	if string(buf) != "first\n" {
		t.Fatalf("first chunk = %q, want %q", buf, "first\n")
	}
	close(release)
	rest, _ := io.ReadAll(resp.Body)
	if string(rest) != "second\n" {
		t.Fatalf("rest = %q, want %q", rest, "second\n")
	}
}

func TestTheBearerTokenIsNotForwarded(t *testing.T) {
	var got http.Header
	daemon := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = r.Header.Clone()
		w.Write([]byte("{}"))
	}))
	defer daemon.Close()
	h, err := New("tcp://" + daemon.Listener.Addr().String())
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	req := httptest.NewRequest(http.MethodPost, "/images/create?fromImage=nginx", nil)
	req.Header.Set("Authorization", "Bearer dm1.abcd1234.secret")
	req.Header.Set("X-Registry-Auth", "registry-credentials")
	h.ServeHTTP(httptest.NewRecorder(), req)
	if got.Get("Authorization") != "" {
		t.Fatalf("the daemon saw Authorization: %q", got.Get("Authorization"))
	}
	if got.Get("X-Registry-Auth") != "registry-credentials" {
		t.Fatal("X-Registry-Auth was not forwarded")
	}
}

func TestAnUnreachableDaemonIsAJSON502(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	addr := ln.Addr().String()
	ln.Close() // nothing listens there any more
	h, err := New("tcp://" + addr)
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/containers/json", nil))
	if rec.Code != http.StatusBadGateway {
		t.Fatalf("code = %d, want 502", rec.Code)
	}
	var body map[string]string
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body["message"] != "The agent cannot reach the Docker daemon" {
		t.Fatalf("body = %q", rec.Body.String())
	}
}
