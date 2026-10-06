// Package state keeps what the agent must remember between runs: the folder
// it owns and the list of paired devices.
package state

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Dir is the state folder. Only the user the agent runs as may enter it.
type Dir struct{ path string }

// Open creates the folder if needed (mode 0700) and checks it is writable.
func Open(path string) (*Dir, error) {
	if path == "" {
		return nil, errors.New("state folder path is empty")
	}
	if err := os.MkdirAll(path, 0o700); err != nil {
		return nil, fmt.Errorf("state folder %s: %w", path, err)
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return nil, fmt.Errorf("state folder %s: %w", path, err)
	}
	probe, err := os.CreateTemp(path, ".probe-*")
	if err != nil {
		return nil, fmt.Errorf("state folder %s is not writable: %w", path, err)
	}
	probe.Close()
	os.Remove(probe.Name())
	return &Dir{path: path}, nil
}

// Path returns the full path of a file in the folder.
func (d *Dir) Path(name string) string { return filepath.Join(d.path, name) }

// ReadFile reads a file from the folder.
func (d *Dir) ReadFile(name string) ([]byte, error) { return os.ReadFile(d.Path(name)) }

// WriteFile replaces a file atomically: the data goes to a temporary file in
// the same folder (mode 0600), is synced, then renamed over the target.
func (d *Dir) WriteFile(name string, data []byte) error {
	tmp, err := os.CreateTemp(d.path, "."+name+".*")
	if err != nil {
		return fmt.Errorf("write %s: %w", name, err)
	}
	tmpName := tmp.Name()
	fail := func(err error) error {
		tmp.Close()
		os.Remove(tmpName)
		return fmt.Errorf("write %s: %w", name, err)
	}
	if err := tmp.Chmod(0o600); err != nil {
		return fail(err)
	}
	if _, err := tmp.Write(data); err != nil {
		return fail(err)
	}
	if err := tmp.Sync(); err != nil {
		return fail(err)
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmpName)
		return fmt.Errorf("write %s: %w", name, err)
	}
	if err := os.Rename(tmpName, d.Path(name)); err != nil {
		os.Remove(tmpName)
		return fmt.Errorf("write %s: %w", name, err)
	}
	return nil
}
