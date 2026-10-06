package server

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"math"
	"net/http"
	"strconv"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/auth"
	"github.com/retransmit/docker-mobile/agent/internal/pairing"
	"github.com/retransmit/docker-mobile/agent/internal/throttle"
)

const (
	// maxPairBody is far more than a pairing request needs.
	maxPairBody = 4 << 10
	// pairBodyTimeout is how long a pairing request may take to arrive.
	pairBodyTimeout = 10 * time.Second
)

type pairRequest struct {
	V     int    `json:"v"`
	Nonce string `json:"nonce"`
	Proof string `json:"proof"`
	Name  string `json:"name"`
}

type deviceInfo struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	Role string `json:"role"`
}

type agentInfo struct {
	Version string `json:"version"`
	API     int    `json:"api"`
}

type pairResponse struct {
	Nonce  string     `json:"nonce"`
	Proof  string     `json:"proof"`
	Token  string     `json:"token"`
	Device deviceInfo `json:"device"`
	Agent  agentInfo  `json:"agent"`
}

type whoamiResponse struct {
	Device deviceInfo `json:"device"`
	Agent  agentInfo  `json:"agent"`
}

// handlePair is the one endpoint a stranger may call. It answers nothing
// useful unless a pairing is pending and the caller proves it holds the code.
func (s *server) handlePair(w http.ResponseWriter, r *http.Request) {
	key := throttle.Key(r.RemoteAddr)
	if left, blocked := s.o.Limiter.Blocked(key); blocked {
		w.Header().Set("Retry-After", strconv.Itoa(int(math.Ceil(left.Seconds()))))
		auth.WriteError(w, http.StatusTooManyRequests, "Too many failed attempts from this address")
		return
	}
	// A stranger may call this, so the body must arrive promptly: without a
	// deadline a slow sender could hold the connection open for ever.
	rc := http.NewResponseController(w)
	rc.SetReadDeadline(time.Now().Add(pairBodyTimeout))
	var req pairRequest
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxPairBody))
	rc.SetReadDeadline(time.Time{})
	if err != nil || json.Unmarshal(body, &req) != nil || req.V != 1 {
		auth.WriteError(w, http.StatusBadRequest, "malformed pairing request")
		return
	}
	nonce, errN := base64.RawURLEncoding.DecodeString(req.Nonce)
	proof, errP := base64.RawURLEncoding.DecodeString(req.Proof)
	if errN != nil || errP != nil || len(nonce) != pairing.NonceLen || len(proof) == 0 {
		auth.WriteError(w, http.StatusBadRequest, "malformed pairing request")
		return
	}
	got, err := s.o.Pairing.Redeem(s.o.Fingerprint, nonce, proof, req.Name, s.o.Devices.Add)
	switch {
	case errors.Is(err, pairing.ErrNone):
		auth.WriteError(w, http.StatusNotFound, "No pairing is in progress on this agent")
		return
	case errors.Is(err, pairing.ErrWrongProof):
		s.o.Limiter.Fail(key)
		s.failures.note(r.RemoteAddr)
		auth.WriteError(w, http.StatusForbidden, "The pairing code is wrong")
		return
	case err != nil:
		s.o.Log.Error("pairing failed", "error", err.Error())
		auth.WriteError(w, http.StatusInternalServerError, "The agent could not store the new device")
		return
	}
	s.o.Log.Info("device paired", "device", got.Device.ID, "name", got.Device.Name, "role", string(got.Device.Role))
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Cache-Control", "no-store")
	json.NewEncoder(w).Encode(pairResponse{
		Nonce:  base64.RawURLEncoding.EncodeToString(got.AgentNonce),
		Proof:  base64.RawURLEncoding.EncodeToString(got.AgentProof),
		Token:  got.Token,
		Device: deviceInfo{ID: got.Device.ID, Name: got.Device.Name, Role: string(got.Device.Role)},
		Agent:  agentInfo{Version: s.o.Version, API: APILevel},
	})
}

// handleWhoami tells a device what the agent knows it as.
func (s *server) handleWhoami(w http.ResponseWriter, r *http.Request) {
	dev, _ := auth.Caller(r.Context())
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(whoamiResponse{
		Device: deviceInfo{ID: dev.ID, Name: dev.Name, Role: string(dev.Role)},
		Agent:  agentInfo{Version: s.o.Version, API: APILevel},
	})
}
