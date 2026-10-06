package state

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
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

type clock struct{ t time.Time }

func (c *clock) now() time.Time          { return c.t }
func (c *clock) advance(d time.Duration) { c.t = c.t.Add(d) }

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
	s, _ := LoadDevices(d, newClock().now)
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
	// A device whose removal could not be stored keeps working.
	if _, ok := s.Authenticate(keptToken); !ok {
		t.Fatal("the device was dropped although its removal failed")
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
