// Package server composes the agent's HTTP handler: an unauthenticated health
// check plus the token-gated transparent Docker proxy.
package server

import (
	"net/http"

	"github.com/0xLennox07/docker-mobile/agent/internal/auth"
	"github.com/0xLennox07/docker-mobile/agent/internal/config"
	"github.com/0xLennox07/docker-mobile/agent/internal/proxy"
)

func Handler(cfg config.Config) (http.Handler, error) {
	dockerProxy, err := proxy.New(cfg.DockerHost)
	if err != nil {
		return nil, err
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})
	mux.Handle("/", auth.RequireToken(cfg.Token, dockerProxy))
	return mux, nil
}
