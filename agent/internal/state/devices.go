package state

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode"
)

// Role is what a paired device may do.
type Role string

const (
	RoleFull     Role = "full"
	RoleReadOnly Role = "readonly"
)

// Valid reports whether r is a known role.
func (r Role) Valid() bool { return r == RoleFull || r == RoleReadOnly }

// Device is one paired phone. The token itself is never stored, only its hash.
type Device struct {
	ID         string    `json:"id"`
	Name       string    `json:"name"`
	Role       Role      `json:"role"`
	TokenHash  string    `json:"tokenHash"`
	CreatedAt  time.Time `json:"createdAt"`
	LastSeenAt time.Time `json:"lastSeenAt"`
}

const (
	devicesFile = "devices.json"
	tokenPrefix = "dm1."
	// lastSeenEvery limits how often a last-seen time reaches the disk.
	lastSeenEvery = time.Minute
	maxNameRunes  = 40
)

// Devices is the persisted list of paired devices, safe for concurrent use.
type Devices struct {
	dir  *Dir
	now  func() time.Time
	rand io.Reader

	mu        sync.Mutex
	byID      map[string]*Device
	persisted map[string]time.Time // last-seen value already on disk, per id
}

// LoadDevices reads the list from the folder. A missing file is an empty
// list. A file that cannot be parsed is an error, so the agent never starts
// as if nobody had been paired.
func LoadDevices(dir *Dir, now func() time.Time) (*Devices, error) {
	s := &Devices{dir: dir, now: now, rand: rand.Reader, byID: map[string]*Device{}, persisted: map[string]time.Time{}}
	data, err := dir.ReadFile(devicesFile)
	if errors.Is(err, os.ErrNotExist) {
		return s, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read %s: %w", devicesFile, err)
	}
	const hint = "fix or remove it (removing it unpairs every device)"
	var list []Device
	if err := json.Unmarshal(data, &list); err != nil {
		return nil, fmt.Errorf("%s is damaged: %v; %s", devicesFile, err, hint)
	}
	for i := range list {
		d := list[i]
		if d.ID == "" || !d.Role.Valid() || len(d.TokenHash) != sha256.Size*2 {
			return nil, fmt.Errorf("%s is damaged: entry %d is incomplete; %s", devicesFile, i, hint)
		}
		s.byID[d.ID] = &d
		s.persisted[d.ID] = d.LastSeenAt
	}
	return s, nil
}

// CleanName makes a device name safe to store and print: printable
// characters only, trimmed, at most 40 runes, never empty.
func CleanName(name string) string {
	var b strings.Builder
	n := 0
	for _, r := range strings.TrimSpace(name) {
		if !unicode.IsPrint(r) {
			continue
		}
		if n == maxNameRunes {
			break
		}
		b.WriteRune(r)
		n++
	}
	out := strings.TrimSpace(b.String())
	if out == "" {
		return "device"
	}
	return out
}

// Add creates a device and returns it with its token. The token exists only
// in this return value; the list keeps its hash.
func (s *Devices) Add(name string, role Role) (Device, string, error) {
	if !role.Valid() {
		return Device{}, "", fmt.Errorf("unknown role %q", role)
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var id string
	for {
		raw := make([]byte, 4)
		if _, err := io.ReadFull(s.rand, raw); err != nil {
			return Device{}, "", fmt.Errorf("random id: %w", err)
		}
		id = hex.EncodeToString(raw)
		if _, taken := s.byID[id]; !taken {
			break
		}
	}
	secret := make([]byte, 32)
	if _, err := io.ReadFull(s.rand, secret); err != nil {
		return Device{}, "", fmt.Errorf("random token: %w", err)
	}
	token := tokenPrefix + id + "." + base64.RawURLEncoding.EncodeToString(secret)
	now := s.now().UTC()
	d := &Device{ID: id, Name: CleanName(name), Role: role, TokenHash: hashToken(token), CreatedAt: now, LastSeenAt: now}
	s.byID[id] = d
	if err := s.saveLocked(); err != nil {
		delete(s.byID, id)
		return Device{}, "", err
	}
	return *d, token, nil
}

// IsDeviceToken reports whether a bearer value has the shape of a device
// token, as opposed to the shared token from the environment.
func IsDeviceToken(token string) bool { return strings.HasPrefix(token, tokenPrefix) }

// Authenticate returns the device a token belongs to. It records when the
// device was seen, writing that to disk at most once a minute per device.
func (s *Devices) Authenticate(token string) (Device, bool) {
	rest, ok := strings.CutPrefix(token, tokenPrefix)
	if !ok {
		return Device{}, false
	}
	id, _, ok := strings.Cut(rest, ".")
	if !ok {
		return Device{}, false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	d, found := s.byID[id]
	if !found {
		return Device{}, false
	}
	if subtle.ConstantTimeCompare([]byte(hashToken(token)), []byte(d.TokenHash)) != 1 {
		return Device{}, false
	}
	now := s.now().UTC()
	d.LastSeenAt = now
	if now.Sub(s.persisted[id]) >= lastSeenEvery {
		// Best effort: a failed write must not lock a paired device out.
		_ = s.saveLocked()
	}
	return *d, true
}

// List returns the devices, oldest first.
func (s *Devices) List() []Device {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]Device, 0, len(s.byID))
	for _, d := range s.byID {
		out = append(out, *d)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].CreatedAt.Before(out[j].CreatedAt)
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// Remove deletes a device. Check the error first: when it is set the device
// is still paired in the running agent, whatever the bool says, and whether
// the file on disk still lists it is not known. The write may have failed
// before the file was replaced, or only afterwards, when the folder was
// synced. Without an error the bool is false when no device has that id.
func (s *Devices) Remove(id string) (Device, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, found := s.byID[id]
	if !found {
		return Device{}, false, nil
	}
	delete(s.byID, id)
	if err := s.saveLocked(); err != nil {
		s.byID[id] = d
		return Device{}, false, err
	}
	delete(s.persisted, id)
	return *d, true, nil
}

func (s *Devices) saveLocked() error {
	list := make([]Device, 0, len(s.byID))
	for _, d := range s.byID {
		list = append(list, *d)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].ID < list[j].ID })
	data, err := json.MarshalIndent(list, "", "  ")
	if err != nil {
		return fmt.Errorf("encode %s: %w", devicesFile, err)
	}
	if err := s.dir.WriteFile(devicesFile, append(data, '\n')); err != nil {
		return err
	}
	for _, d := range list {
		s.persisted[d.ID] = d.LastSeenAt
	}
	return nil
}

func hashToken(token string) string {
	sum := sha256.Sum256([]byte(token))
	return hex.EncodeToString(sum[:])
}
