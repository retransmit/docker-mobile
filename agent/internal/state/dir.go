// Package state keeps what the agent must remember between runs: the folder
// it owns and the list of paired devices.
package state

import (
	"crypto/rand"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
)

// Dir is the state folder. Only the user the agent runs as may enter it.
type Dir struct{ path string }

// probePrefix is how the name of a probe begins: the file that Open writes
// and removes again to find out whether the folder can store one. A random
// part follows it, so every call tries the folder with a file of its own. An
// agent that is already running on the folder loses nothing by that, and two
// agents that are started in the same moment do not get at each other's file:
// on Windows, a name they shared would fail one of them, renaming onto what
// the other is just removing.
const probePrefix = "probe."

// ownFiles are the names of the files the agent keeps in its state folder,
// each with who writes it. Open takes a folder that was there before only if
// it holds nothing else, apart from probes. The other packages cannot be
// asked for their names, because they import this one: a file that gets
// another name there needs it here as well.
var ownFiles = []string{
	devicesFile,  // the paired devices: this package
	"tls.key",    // the key of the agent's certificate: package tlsid
	"tls.crt",    // the certificate: package tlsid
	"admin.sock", // the socket the command line talks to: package admin
	"agent.lock", // the lock that keeps a second agent off the folder: package admin
}

// Open returns the state folder at path, which must be the agent's own. A
// folder that is not there is created with mode 0700. A folder that is there
// is taken only if it belongs to the user the agent runs as (on Unix; on
// Windows the owner is not looked at) and holds nothing but the agent's own
// files; its mode is then set to 0700. Any other folder is refused and left
// exactly as it was: a folder that others use, such as a home folder or /tmp,
// must not be made private, and the agent's files must not lie where another
// user can replace them.
//
// A folder that cannot store a file is refused too, so that a full disk or a
// file system that cannot sync stops the agent when it starts and not at the
// first pairing.
func Open(path string) (*Dir, error) {
	if path == "" {
		return nil, errors.New("state folder path is empty")
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return nil, fmt.Errorf("state folder %s: %w", path, err)
	}
	// Mkdir says whether the folder is new, and not a look beforehand: a
	// folder that someone else makes in this very moment is then checked like
	// any other that was there. When Mkdir fails and nothing is at the path,
	// its error is the one to report.
	if mkdirErr := os.Mkdir(path, 0o700); mkdirErr != nil {
		info, err := os.Stat(path)
		if err != nil {
			return nil, fmt.Errorf("state folder %s: %w", path, mkdirErr)
		}
		if err := checkExisting(path, info); err != nil {
			return nil, err
		}
	}
	if err := os.Chmod(path, 0o700); err != nil {
		return nil, fmt.Errorf("state folder %s: %w", path, err)
	}
	d := &Dir{path: path}
	if err := d.probe(probePrefix + rand.Text()); err != nil {
		return nil, err
	}
	return d, nil
}

// probe finds out whether the folder can store a file. It writes one called
// name the way every file of the agent is written, synced and renamed into
// place, and removes it again.
func (d *Dir) probe(name string) error {
	err := d.WriteFile(name, []byte("probe\n"))
	os.Remove(d.Path(name))
	if err != nil {
		return fmt.Errorf("state folder %s cannot store a file: %w", d.path, err)
	}
	return nil
}

// checkExisting decides whether what was at path before Open may be the
// state folder. info is what Stat says about it. Nothing is changed here.
func checkExisting(path string, info fs.FileInfo) error {
	if !info.IsDir() {
		return fmt.Errorf("state folder %s is not a folder", path)
	}
	if err := checkOwner(path, info); err != nil {
		return err
	}
	entries, err := os.ReadDir(path)
	if err != nil {
		return fmt.Errorf("state folder %s: %w", path, err)
	}
	for _, e := range entries {
		if !isOwn(e) {
			return fmt.Errorf("state folder %s holds other files (%q is one): the agent needs a folder of its own, set AGENT_DATA to one that is empty or does not exist yet", path, e.Name())
		}
	}
	return nil
}

// sameUser refuses a folder whose owner is not the user the agent runs as:
// owner is the user id the folder belongs to, user the effective one of the
// agent. Whoever owns the folder can replace what is in it, the device list
// and the key included.
func sameUser(path string, owner, user uint32) error {
	if owner != user {
		return fmt.Errorf("state folder %s belongs to another user (uid %d, and the agent runs as uid %d): run the agent as that user, or set AGENT_DATA to a folder of the agent's own", path, owner, user)
	}
	return nil
}

// isOwn reports whether an entry of the state folder is the agent's own: one
// of ownFiles, a probe, or a temporary file that WriteFile made for one of
// those. An agent may be writing such a file right now, or have left it
// behind when it died. A folder named lost+found passes as well: a freshly
// formatted disk that is mounted at the path comes with one.
func isOwn(e fs.DirEntry) bool {
	name := e.Name()
	if name == "lost+found" {
		return e.IsDir()
	}
	for _, own := range ownFiles {
		if name == own || begins(name, tempPrefix(own)) {
			return true
		}
	}
	// The temporary file of a probe begins with a dot, like every other.
	return begins(name, probePrefix) || begins(name, "."+probePrefix)
}

// begins reports whether name starts with prefix and goes on after it.
func begins(name, prefix string) bool {
	return len(name) > len(prefix) && strings.HasPrefix(name, prefix)
}

// tempPrefix is how the name of the temporary file begins that WriteFile
// makes on the way to name. A random part follows it.
func tempPrefix(name string) string { return "." + name + "." }

// Path returns the full path of a file in the folder.
func (d *Dir) Path(name string) string { return filepath.Join(d.path, name) }

// ReadFile reads a file from the folder.
func (d *Dir) ReadFile(name string) ([]byte, error) { return os.ReadFile(d.Path(name)) }

// WriteFile replaces a file atomically: the data goes to a temporary file in
// the same folder (mode 0600), is synced, then renamed over the target, and
// the folder is synced so the rename survives a power cut. When only that
// last step fails the target has already been replaced: the error then means
// "replaced, but not known to be durable".
func (d *Dir) WriteFile(name string, data []byte) error {
	tmp, err := os.CreateTemp(d.path, tempPrefix(name)+"*")
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
	if err := syncDir(d.path); err != nil {
		return fmt.Errorf("write %s: %w", name, err)
	}
	return nil
}

// syncDir makes a rename inside the folder durable. Windows cannot sync a
// folder and a few file systems refuse to (EINVAL); both are left alone.
func syncDir(path string) error {
	if runtime.GOOS == "windows" {
		return nil
	}
	f, err := os.Open(path)
	if err != nil {
		return err
	}
	err = f.Sync()
	if closeErr := f.Close(); err == nil {
		err = closeErr
	}
	if errors.Is(err, syscall.EINVAL) {
		return nil
	}
	return err
}
