// Command agent runs the docker-mobile companion agent.
package main

import (
	"log"
	"net/http"
	"os"

	"github.com/0xLennox07/docker-mobile/agent/internal/config"
	"github.com/0xLennox07/docker-mobile/agent/internal/server"
)

func main() {
	cfg, err := config.Load(os.Getenv)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	h, err := server.Handler(cfg)
	if err != nil {
		log.Fatalf("server: %v", err)
	}
	log.Printf("docker-mobile-agent listening on %s (docker host: %s)", cfg.ListenAddr, cfg.DockerHost)
	if err := http.ListenAndServe(cfg.ListenAddr, h); err != nil {
		log.Fatalf("listen: %v", err)
	}
}
