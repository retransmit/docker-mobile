package state

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

func openTemp(t *testing.T) *Dir {
	t.Helper()
	d, err := Open(filepath.Join(t.TempDir(), "data"))
	if err != nil {
		t.Fatalf("Open: %v", err)
	}
	return d
}

// clock is a time source the tests set by hand. Goroutines may share it.
type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.t
}

func (c *clock) advance(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.t = c.t.Add(d)
}

func newClock() *clock { return &clock{t: time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)} }

func TestOpenCreatesAPrivateFolder(t *testing.T) {
	path := filepath.Join(t.TempDir(), "a", "b")
	if _, err := Open(path); err != nil {
		t.Fatalf("Open: %v", err)
	}
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() {
		t.Fatalf("folder missing: %v", err)
	}
	if runtime.GOOS != "windows" && info.Mode().Perm() != 0o700 {
		t.Fatalf("mode = %v, want 0700", info.Mode().Perm())
	}
}

func TestOpenRejectsAnEmptyPathAndAFile(t *testing.T) {
	if _, err := Open(""); err == nil {
		t.Fatal("empty path accepted")
	}
	file := filepath.Join(t.TempDir(), "f")
	if err := os.WriteFile(file, []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := Open(file); err == nil {
		t.Fatal("a plain file accepted as the state folder")
	}
}

// folderWith makes a folder with mode 0755 that holds a file for every name
// and returns its path. A name that ends in a slash becomes a folder. The
// folder says it was last written to long ago: whatever is written into it
// afterwards moves that time, also a file that is made there and removed
// again.
func folderWith(t *testing.T, names ...string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "data")
	if err := os.Mkdir(path, 0o755); err != nil {
		t.Fatal(err)
	}
	// Whatever the umask made of it.
	if err := os.Chmod(path, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range names {
		var err error
		if dir, isDir := strings.CutSuffix(name, "/"); isDir {
			err = os.Mkdir(filepath.Join(path, dir), 0o700)
		} else {
			err = os.WriteFile(filepath.Join(path, name), []byte(name), 0o600)
		}
		if err != nil {
			t.Fatal(err)
		}
	}
	longAgo := time.Date(2001, 2, 3, 4, 5, 6, 0, time.UTC)
	if err := os.Chtimes(path, longAgo, longAgo); err != nil {
		t.Fatal(err)
	}
	return path
}

// holds returns the names of what is in the folder at path, sorted.
func holds(t *testing.T, path string) []string {
	t.Helper()
	entries, err := os.ReadDir(path)
	if err != nil {
		t.Fatal(err)
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		names = append(names, e.Name())
	}
	return names
}

// statFolder returns what the system says about the folder at path.
func statFolder(t *testing.T, path string) os.FileInfo {
	t.Helper()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	return info
}

func TestOpenTakesAnEmptyFolderThatWasThereAndMakesItPrivate(t *testing.T) {
	path := folderWith(t)
	before := statFolder(t, path)
	if _, err := Open(path); err != nil {
		t.Fatalf("Open: %v", err)
	}
	after := statFolder(t, path)
	if runtime.GOOS != "windows" && after.Mode().Perm() != 0o700 {
		t.Fatalf("mode = %v, want 0700", after.Mode().Perm())
	}
	// Open has tried the folder with a file, and removed it again.
	if after.ModTime().Equal(before.ModTime()) {
		t.Fatal("nothing was written into the folder to try it")
	}
	if left := holds(t, path); len(left) != 0 {
		t.Fatalf("Open left something in the folder: %v", left)
	}
}

func TestOpenTakesAFolderThatHoldsOnlyTheAgentsFiles(t *testing.T) {
	// What an agent keeps in its folder, what it leaves there when it dies
	// while it writes one of its files or tries the folder, and what a
	// freshly formatted disk comes with.
	path := folderWith(t,
		"admin.sock", "agent.lock", "devices.json", "tls.crt", "tls.key",
		".devices.json.1234567890", ".tls.crt.42", ".tls.key.42",
		"probe.LEFTBEHIND", ".probe.LEFTBEHIND.7",
		"lost+found/",
	)
	held := holds(t, path)
	if _, err := Open(path); err != nil {
		t.Fatalf("Open: %v", err)
	}
	if after := statFolder(t, path); runtime.GOOS != "windows" && after.Mode().Perm() != 0o700 {
		t.Fatalf("mode = %v, want 0700", after.Mode().Perm())
	}
	// Everything in it is as it was, and nothing was added.
	if now := holds(t, path); strings.Join(now, "\n") != strings.Join(held, "\n") {
		t.Fatalf("the folder holds %v after Open, it held %v", now, held)
	}
	for _, name := range held {
		if name == "lost+found" {
			continue
		}
		if got, err := os.ReadFile(filepath.Join(path, name)); err != nil || string(got) != name {
			t.Errorf("%s was changed: %q, %v", name, got, err)
		}
	}
}

func TestOpenRefusesAFolderThatHoldsAnotherFileAndLeavesItAlone(t *testing.T) {
	others := []string{
		"notes.txt",
		".bashrc",
		"devices.json.bak", // the name of a file of the agent with something after it
		".notes.txt.42",    // a temporary file for a file that is not the agent's
		"probe",            // what the name of a probe begins with, without its random part
		"lost+found",       // a file, where only a folder of that name is let pass
		"sub/",
	}
	if runtime.GOOS != "windows" {
		// What a temporary file begins with, and nothing after it. Windows
		// drops a dot at the end of a name, so the file cannot be made there.
		others = append(others, ".devices.json.")
	}
	for _, other := range others {
		// The one file that is not the agent's lies among files that are.
		path := folderWith(t, "devices.json", other, "tls.key")
		held, before := holds(t, path), statFolder(t, path)
		_, err := Open(path)
		if err == nil {
			t.Errorf("a folder that holds %s was accepted", other)
			continue
		}
		name := strings.TrimSuffix(other, "/")
		for _, want := range []string{path, `"` + name + `"`, "folder of its own"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("%s: the error does not say %s: %v", other, want, err)
			}
		}
		if strings.Contains(err.Error(), "\n") {
			t.Errorf("%s: the error is more than one line: %q", other, err)
		}
		// The folder is as it was: its mode, what it holds, and when it was
		// last written to.
		after := statFolder(t, path)
		if runtime.GOOS != "windows" && after.Mode().Perm() != 0o755 {
			t.Errorf("%s: the mode of the refused folder is now %v, it was 0755", other, after.Mode().Perm())
		}
		if now := holds(t, path); strings.Join(now, "\n") != strings.Join(held, "\n") {
			t.Errorf("%s: the refused folder holds %v, it held %v", other, now, held)
		}
		if !after.ModTime().Equal(before.ModTime()) {
			t.Errorf("%s: something was written into the refused folder", other)
		}
	}
}

func TestAFolderMustBelongToTheUserTheAgentRunsAs(t *testing.T) {
	for _, same := range []uint32{0, 1000} {
		if err := sameUser("/srv/agent", same, same); err != nil {
			t.Errorf("a folder of uid %d was refused to an agent that runs as uid %d: %v", same, same, err)
		}
	}
	for _, c := range []struct{ owner, user uint32 }{
		{1000, 0}, // root must not take a folder that another user can fill
		{0, 1000},
		{1000, 1001},
	} {
		err := sameUser("/srv/agent", c.owner, c.user)
		if err == nil {
			t.Errorf("a folder of uid %d was given to an agent that runs as uid %d", c.owner, c.user)
			continue
		}
		for _, want := range []string{"/srv/agent", "another user", "AGENT_DATA"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("owner %d, agent %d: the error does not say %q: %v", c.owner, c.user, want, err)
			}
		}
	}
}

func TestAFolderThatCannotStoreTheProbeIsAClearError(t *testing.T) {
	d := openTemp(t)
	// Where the probe goes there is a folder that is not empty, so the probe
	// cannot be renamed into place: the folder takes no file of that name.
	const name = "probe.x"
	if err := os.Mkdir(d.Path(name), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(d.Path(name), "x"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	err := d.probe(name)
	if err == nil {
		t.Fatal("the probe reported success although it could not be stored")
	}
	for _, want := range []string{d.Path(""), "cannot store a file"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the error does not say %q: %v", want, err)
		}
	}
	// Nothing of the attempt is left behind.
	if left := holds(t, d.Path("")); len(left) != 1 || left[0] != name {
		t.Fatalf("the folder holds %v, want only what was in the way", left)
	}
}

func TestWriteFileIsAtomicAndPrivate(t *testing.T) {
	d := openTemp(t)
	if err := d.WriteFile("x.json", []byte("one")); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	if err := d.WriteFile("x.json", []byte("two")); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}
	got, err := d.ReadFile("x.json")
	if err != nil || string(got) != "two" {
		t.Fatalf("read = %q, %v", got, err)
	}
	entries, _ := os.ReadDir(filepath.Dir(d.Path("x.json")))
	if len(entries) != 1 {
		t.Fatalf("leftover files: %v", entries)
	}
	if runtime.GOOS != "windows" {
		info, _ := os.Stat(d.Path("x.json"))
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("mode = %v, want 0600", info.Mode().Perm())
		}
	}
}

func TestAddReturnsATokenThatAuthenticates(t *testing.T) {
	d := openTemp(t)
	s, err := LoadDevices(d, newClock().now)
	if err != nil {
		t.Fatal(err)
	}
	dev, token, err := s.Add("  Pixel 8\n", RoleReadOnly)
	if err != nil {
		t.Fatalf("Add: %v", err)
	}
	if dev.Name != "Pixel 8" || dev.Role != RoleReadOnly || len(dev.ID) != 8 {
		t.Fatalf("device = %+v", dev)
	}
	if !strings.HasPrefix(token, "dm1."+dev.ID+".") || len(token) != len("dm1.")+8+1+43 {
		t.Fatalf("token shape = %q", token)
	}
	if !IsDeviceToken(token) || IsDeviceToken("some-shared-token") {
		t.Fatal("IsDeviceToken is wrong")
	}
	got, ok := s.Authenticate(token)
	if !ok || got.ID != dev.ID {
		t.Fatalf("Authenticate = %+v, %v", got, ok)
	}
	for _, bad := range []string{"", "dm1.", "dm1." + dev.ID, "dm1." + dev.ID + ".wrong", "dm1.ffffffff.x", token + "x", strings.ToUpper(token)} {
		if _, ok := s.Authenticate(bad); ok {
			t.Fatalf("accepted %q", bad)
		}
	}
}

func TestTheTokenIsNotStored(t *testing.T) {
	d := openTemp(t)
	s, _ := LoadDevices(d, newClock().now)
	_, token, err := s.Add("phone", RoleFull)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := d.ReadFile("devices.json")
	if err != nil {
		t.Fatal(err)
	}
	secret := token[strings.LastIndex(token, ".")+1:]
	if strings.Contains(string(raw), secret) {
		t.Fatal("the token secret is in devices.json")
	}
}

func TestDevicesSurviveAReload(t *testing.T) {
	d := openTemp(t)
	c := newClock()
	s, _ := LoadDevices(d, c.now)
	a, tokenA, _ := s.Add("a", RoleFull)
	c.advance(time.Second)
	b, _, _ := s.Add("b", RoleReadOnly)

	again, err := LoadDevices(d, c.now)
	if err != nil {
		t.Fatalf("reload: %v", err)
	}
	list := again.List()
	if len(list) != 2 || list[0].ID != a.ID || list[1].ID != b.ID {
		t.Fatalf("list = %+v", list)
	}
	if _, ok := again.Authenticate(tokenA); !ok {
		t.Fatal("token no longer authenticates after a reload")
	}
}

func TestRemoveStopsAuthentication(t *testing.T) {
	d := openTemp(t)
	s, _ := LoadDevices(d, newClock().now)
	dev, token, _ := s.Add("phone", RoleFull)
	removed, ok, err := s.Remove(dev.ID)
	if err != nil || !ok || removed.ID != dev.ID {
		t.Fatalf("Remove = %+v, %v, %v", removed, ok, err)
	}
	if _, ok := s.Authenticate(token); ok {
		t.Fatal("a removed device still authenticates")
	}
	if _, ok, _ := s.Remove(dev.ID); ok {
		t.Fatal("removing twice reported success")
	}
	again, _ := LoadDevices(d, newClock().now)
	if len(again.List()) != 0 {
		t.Fatal("the removed device came back after a reload")
	}
}

func TestLastSeenReachesTheDiskAtMostOnceAMinute(t *testing.T) {
	d := openTemp(t)
	c := newClock()
	s, _ := LoadDevices(d, c.now)
	dev, token, _ := s.Add("phone", RoleFull)

	onDisk := func() time.Time {
		t.Helper()
		again, err := LoadDevices(d, c.now)
		if err != nil {
			t.Fatal(err)
		}
		return again.List()[0].LastSeenAt
	}
	c.advance(30 * time.Second)
	s.Authenticate(token)
	if !onDisk().Equal(dev.CreatedAt) {
		t.Fatal("last seen was written within the minute")
	}
	if !s.List()[0].LastSeenAt.Equal(c.now()) {
		t.Fatal("last seen is not current in memory")
	}
	c.advance(31 * time.Second)
	s.Authenticate(token)
	if !onDisk().Equal(c.now()) {
		t.Fatal("last seen was not written after a minute")
	}
}

func TestADamagedFileStopsTheLoad(t *testing.T) {
	for name, content := range map[string]string{
		"not json":   "{",
		"incomplete": `[{"id":"","name":"x","role":"full","tokenHash":""}]`,
		"bad role":   `[{"id":"abcd1234","name":"x","role":"admin","tokenHash":"` + strings.Repeat("a", 64) + `"}]`,
	} {
		d := openTemp(t)
		if err := d.WriteFile("devices.json", []byte(content)); err != nil {
			t.Fatal(err)
		}
		if _, err := LoadDevices(d, newClock().now); err == nil || !strings.Contains(err.Error(), "damaged") {
			t.Fatalf("%s: err = %v, want a damaged-file error", name, err)
		}
	}
}

func TestAFailedWriteLeavesNoDeviceBehind(t *testing.T) {
	d := openTemp(t)
	c := newClock()
	s, _ := LoadDevices(d, c.now)
	kept, keptToken, err := s.Add("kept", RoleFull)
	if err != nil {
		t.Fatal(err)
	}
	// The folder disappears: nothing can be written any more.
	if err := os.RemoveAll(d.Path("")); err != nil {
		t.Fatal(err)
	}
	if _, _, err := s.Add("lost", RoleFull); err == nil {
		t.Fatal("Add reported success although nothing could be stored")
	}
	if list := s.List(); len(list) != 1 || list[0].ID != kept.ID {
		t.Fatalf("list = %+v, want only the device that was stored", list)
	}
	if _, _, err := s.Remove(kept.ID); err == nil {
		t.Fatal("Remove reported success although nothing could be stored")
	}
	// A device whose removal could not be stored keeps working. Two minutes
	// on its last-seen time is due on disk; that write fails as well and
	// must not lock the device out either.
	c.advance(2 * time.Minute)
	if _, ok := s.Authenticate(keptToken); !ok {
		t.Fatal("the device stopped working although only writes failed")
	}
}

func TestCleanName(t *testing.T) {
	cases := map[string]string{
		"":                      "device",
		"   ":                   "device",
		"Pixel 8":               "Pixel 8",
		"a\x00b\x1b[31mc":       "ab[31mc",
		strings.Repeat("x", 60): strings.Repeat("x", 40),
		"tab\tname":             "tabname",
	}
	for in, want := range cases {
		if got := CleanName(in); got != want {
			t.Errorf("CleanName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestAddRejectsAnUnknownRole(t *testing.T) {
	s, _ := LoadDevices(openTemp(t), newClock().now)
	if _, _, err := s.Add("x", Role("admin")); err == nil {
		t.Fatal("unknown role accepted")
	}
}

func TestConcurrentUse(t *testing.T) {
	d := openTemp(t)
	c := newClock()
	s, err := LoadDevices(d, c.now)
	if err != nil {
		t.Fatal(err)
	}
	first, token, err := s.Add("first", RoleFull)
	if err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 300; j++ {
				if got, ok := s.Authenticate(token); !ok || got.ID != first.ID {
					t.Errorf("Authenticate = %+v, %v", got, ok)
					return
				}
			}
		}()
	}

	// Every second device added here is removed again; the others stay.
	var kept []string
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 60; i++ {
			dev, _, err := s.Add("other", RoleReadOnly)
			if err != nil {
				t.Errorf("Add: %v", err)
				return
			}
			if len(s.List()) < 2 {
				t.Errorf("the list lost a device")
				return
			}
			if i%2 == 0 {
				kept = append(kept, dev.ID)
				continue
			}
			if _, ok, err := s.Remove(dev.ID); err != nil || !ok {
				t.Errorf("Remove = %v, %v", ok, err)
				return
			}
		}
	}()

	// The clock passes a minute five times, so last-seen times become due on
	// disk while the others are at work.
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; i < 300; i++ {
			if i%60 == 0 {
				c.advance(61 * time.Second)
			}
			s.List()
		}
	}()

	wg.Wait()

	if _, ok := s.Authenticate(token); !ok {
		t.Fatal("the first device no longer authenticates")
	}
	want := map[string]bool{first.ID: true}
	for _, id := range kept {
		want[id] = true
	}
	list := s.List()
	if len(list) != len(want) {
		t.Fatalf("list has %d devices, want %d", len(list), len(want))
	}
	for _, dev := range list {
		if !want[dev.ID] {
			t.Fatalf("device %s is in the list but was removed", dev.ID)
		}
	}
}
