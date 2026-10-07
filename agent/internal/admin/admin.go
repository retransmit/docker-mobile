// Package admin is how the agent's own command line talks to the running
// agent: a small HTTP API on a unix socket inside the state folder. Whoever
// can open that socket can already run commands on the server; nothing here
// is reachable over the network.
package admin

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/retransmit/docker-mobile/agent/internal/config"
	"github.com/retransmit/docker-mobile/agent/internal/conns"
	"github.com/retransmit/docker-mobile/agent/internal/pairing"
	"github.com/retransmit/docker-mobile/agent/internal/state"
)

const (
	socketName = "admin.sock"
	// lockName is the file an agent keeps locked for as long as it serves
	// the state folder.
	lockName = "agent.lock"
	// maxSocketPath is the longest socket path that works everywhere. The
	// address of a unix socket holds 104 bytes on macOS and the BSDs and 108
	// on Linux and Windows, the zero byte that ends the path included.
	maxSocketPath = 103
)

// errLocked means the lock of the state folder is held.
var errLocked = errors.New("locked")

// checkSocketPath refuses a state folder whose admin socket would have a
// path longer than a socket address can hold. Without it the failure would
// read as "invalid argument" in the agent and as no agent running in the
// command line.
func checkSocketPath(path string) error {
	if len(path) > maxSocketPath {
		return fmt.Errorf("the state folder path is too long for the admin socket: %s is %d bytes, the limit is %d", path, len(path), maxSocketPath)
	}
	return nil
}

// PairRequest starts a pairing.
type PairRequest struct {
	// Role is "full" or "readonly"; empty means full.
	Role string `json:"role"`
	// Name fixes the device name; empty lets the phone propose one.
	Name string `json:"name"`
	// Host overrides the advertised address for this pairing.
	Host string `json:"host"`
}

// Event names. A pairing stream is one "started" event followed by exactly
// one of the others.
const (
	EventStarted = "started"
)

// Event is one line of a pairing stream.
type Event struct {
	Event string `json:"event"`
	// Set on "started".
	Code        string `json:"code,omitempty"`        // XXXX-XXXX-XXXX
	Link        string `json:"link,omitempty"`        // dockermobile://pair?...
	Fingerprint string `json:"fingerprint,omitempty"` // SHA256:..., empty without a certificate
	Address     string `json:"address,omitempty"`     // where the code says the agent is, empty if unknown
	Role        string `json:"role,omitempty"`
	ExpiresIn   int    `json:"expiresInSeconds,omitempty"`
	// Set on "paired".
	Device *DeviceInfo `json:"device,omitempty"`
	// Set on "failed".
	Error string `json:"error,omitempty"`
}

// DeviceInfo is a device as the command line shows it. It never carries the
// token hash.
type DeviceInfo struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	Role       string    `json:"role"`
	CreatedAt  time.Time `json:"createdAt"`
	LastSeenAt time.Time `json:"lastSeenAt"`
}

func infoOf(d state.Device) DeviceInfo {
	return DeviceInfo{ID: d.ID, Name: d.Name, Role: string(d.Role), CreatedAt: d.CreatedAt, LastSeenAt: d.LastSeenAt}
}

type devicesResponse struct {
	Devices []DeviceInfo `json:"devices"`
}

type revokeResponse struct {
	Device DeviceInfo `json:"device"`
	Closed int        `json:"closed"`
}

type errorResponse struct {
	Message string `json:"message"`
}

// Server serves the admin API. Pairing, Devices and Conns are required.
type Server struct {
	Pairing *pairing.Manager
	Devices *state.Devices
	Conns   *conns.Registry
	// Advertise is where phones reach the agent.
	Advertise config.Advertise
	// Fingerprint is the pinned form (base64url); empty without a certificate.
	Fingerprint string
	// FingerprintDisplay is the form shown to people.
	FingerprintDisplay string
	// AgentName is how the agent calls itself in pairing codes.
	AgentName string
	Log       *slog.Logger
	// Now and After are the clock; nil means time.Now and time.After.
	Now   func() time.Time
	After func(time.Duration) <-chan time.Time
}

// Listen takes the state folder for this agent and opens the admin socket in
// it. It refuses when another agent is already serving that folder.
//
// What says so is a lock on a file in the folder, held for as long as the
// returned listener is open. The operating system drops the lock when the
// process ends, however it ends, so a lock that is held always means a live
// agent. A socket file found once the lock is taken was left behind by an
// agent that died, and is replaced. Closing the listener removes the socket
// and gives the folder up.
func Listen(dir *state.Dir) (net.Listener, error) {
	if err := checkSocketPath(dir.Path(socketName)); err != nil {
		return nil, err
	}
	lock, err := lockFile(dir.Path(lockName))
	if errors.Is(err, errLocked) {
		return nil, errors.New("another agent is already running on this state folder")
	}
	if err != nil {
		return nil, fmt.Errorf("lock the state folder: %w", err)
	}
	ln, err := listenLocked(dir.Path(socketName))
	if err != nil {
		lock.Close()
		return nil, err
	}
	return &lockedListener{Listener: ln, lock: lock}, nil
}

// listenLocked opens the admin socket at path, in place of whatever is
// there. The caller holds the lock of the folder.
func listenLocked(path string) (net.Listener, error) {
	if err := os.Remove(path); err != nil && !errors.Is(err, fs.ErrNotExist) {
		return nil, fmt.Errorf("remove stale admin socket: %w", err)
	}
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("admin socket: %w", err)
	}
	if err := os.Chmod(path, 0o600); err != nil {
		ln.Close()
		return nil, fmt.Errorf("admin socket: %w", err)
	}
	return ln, nil
}

// lockedListener is the admin socket together with the lock of its folder.
type lockedListener struct {
	net.Listener
	lock *os.File

	once sync.Once
	err  error
}

// Close closes the socket and then gives the folder up. Calling it again
// does nothing and returns what the first call returned.
func (l *lockedListener) Close() error {
	l.once.Do(func() {
		// The socket goes first. Closing it removes whatever is at its path,
		// and once the lock is free that may be the socket of the next agent.
		l.err = l.Listener.Close()
		if err := l.lock.Close(); err != nil && l.err == nil {
			l.err = fmt.Errorf("release the state folder: %w", err)
		}
	})
	return l.err
}

// Handler returns the admin API.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /pair", s.handlePair)
	mux.HandleFunc("GET /devices", s.handleDevices)
	mux.HandleFunc("DELETE /devices/{id}", s.handleRevoke)
	return mux
}

func (s *Server) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Server) after(d time.Duration) <-chan time.Time {
	if s.After != nil {
		return s.After(d)
	}
	return time.After(d)
}

// logf writes one line to the log, if there is one. It is never given a
// pairing code or a token.
func (s *Server) logf(msg string, args ...any) {
	if s.Log != nil {
		s.Log.Info(msg, args...)
	}
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

func (s *Server) handlePair(w http.ResponseWriter, r *http.Request) {
	var req PairRequest
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 4<<10))
	if err != nil || (len(body) > 0 && json.Unmarshal(body, &req) != nil) {
		writeJSON(w, http.StatusBadRequest, errorResponse{"malformed request"})
		return
	}
	role := state.Role(req.Role)
	if req.Role == "" {
		role = state.RoleFull
	}
	if !role.Valid() {
		writeJSON(w, http.StatusBadRequest, errorResponse{fmt.Sprintf("unknown role %q", req.Role)})
		return
	}
	adv, err := s.Advertise.WithHost(req.Host)
	if err != nil {
		writeJSON(w, http.StatusBadRequest, errorResponse{err.Error()})
		return
	}
	p, done, err := s.Pairing.Start(role, req.Name)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, errorResponse{err.Error()})
		return
	}
	link := pairing.Link(pairing.LinkParams{
		Host:        adv.Host,
		Port:        portFor(adv),
		Fingerprint: s.Fingerprint,
		Scheme:      adv.Scheme,
		Code:        p.Code,
		Name:        s.AgentName,
	})
	w.Header().Set("Content-Type", "application/x-ndjson")
	w.WriteHeader(http.StatusOK)
	enc := json.NewEncoder(w)
	send := func(e Event) {
		enc.Encode(e)
		if f, ok := w.(http.Flusher); ok {
			f.Flush()
		}
	}
	send(Event{
		Event:       EventStarted,
		Code:        pairing.Format(p.Code),
		Link:        link,
		Fingerprint: s.FingerprintDisplay,
		Address:     addressOf(adv),
		Role:        string(p.Role),
		ExpiresIn:   int(p.ExpiresAt.Sub(s.now()).Seconds()),
	})

	s.logf("pairing started", "role", string(p.Role))

	var result pairing.Result
	left := false
	select {
	case result = <-done:
	case <-s.after(p.ExpiresAt.Sub(s.now())):
		s.Pairing.Expire(p.ID)
		result = <-done
	case <-r.Context().Done():
		// The command line went away: the code must not stay usable. The
		// pairing may have ended a moment before, even with a device stored,
		// and Cancel then changes nothing. So the result is read, not assumed.
		s.Pairing.Cancel(p.ID)
		result = <-done
		left = true
	}
	if result.Outcome == pairing.Paired {
		s.logf("pairing ended", "outcome", string(result.Outcome), "device", result.Device.ID, "name", result.Device.Name)
	} else {
		s.logf("pairing ended", "outcome", string(result.Outcome))
	}
	if left {
		// No ending event: the request is over, so the stream just breaks
		// off after "started".
		return
	}
	e := Event{Event: string(result.Outcome), Error: result.Err}
	if result.Outcome == pairing.Paired {
		info := infoOf(result.Device)
		e.Device = &info
	}
	send(e)
}

// portFor leaves the port out of a link when there is no host to go with it.
func portFor(a config.Advertise) string {
	if a.Host == "" {
		return ""
	}
	return a.Port
}

// addressOf is the advertised address as a person reads it.
func addressOf(a config.Advertise) string {
	if a.Host == "" {
		return ""
	}
	hostPort := net.JoinHostPort(a.Host, a.Port)
	if a.Scheme != "" {
		return a.Scheme + "://" + hostPort
	}
	return hostPort
}

func (s *Server) handleDevices(w http.ResponseWriter, _ *http.Request) {
	list := s.Devices.List()
	out := devicesResponse{Devices: make([]DeviceInfo, 0, len(list))}
	for _, d := range list {
		out.Devices = append(out.Devices, infoOf(d))
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleRevoke(w http.ResponseWriter, r *http.Request) {
	id := r.PathValue("id")
	dev, found, err := s.Devices.Remove(id)
	if err != nil {
		// The device is back in the list and none of its requests was
		// closed. The answer says that first: the cause alone names a file,
		// and reads as if the phone were gone.
		writeJSON(w, http.StatusInternalServerError, errorResponse{"the device is still paired and its connections stay open: the removal could not be stored: " + err.Error()})
		return
	}
	if !found {
		writeJSON(w, http.StatusNotFound, errorResponse{fmt.Sprintf("no device with id %q", id)})
		return
	}
	closed := s.Conns.CloseDevice(id)
	s.logf("device revoked", "device", dev.ID, "name", dev.Name, "closed", closed)
	writeJSON(w, http.StatusOK, revokeResponse{Device: infoOf(dev), Closed: closed})
}
