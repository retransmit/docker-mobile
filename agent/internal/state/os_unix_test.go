//go:build unix

package state

import (
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestAFolderOfAnotherUserIsRefusedBeforeItIsLookedInto(t *testing.T) {
	// The root folder belongs to root, and it holds a good deal that is not
	// the agent's. It is only looked at here: checkExisting changes nothing.
	const root = "/"
	info, err := os.Stat(root)
	if err != nil {
		t.Fatal(err)
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Uid == uint32(os.Geteuid()) {
		t.Skip("needs a folder of another user, and the root folder belongs to the user who runs the test")
	}
	err = checkExisting(root, info)
	if err == nil {
		t.Fatal("the root folder was taken for the agent's own")
	}
	if !strings.Contains(err.Error(), "another user") {
		t.Fatalf("the root folder was refused for something other than its owner: %v", err)
	}

	// A folder of the user who runs the test passes.
	mine := t.TempDir()
	if info, err = os.Stat(mine); err != nil {
		t.Fatal(err)
	}
	if err := checkExisting(mine, info); err != nil {
		t.Fatalf("a folder of the user who runs the test was refused: %v", err)
	}
}

func TestOpenTrustsWhatAFolderHoldsOnlyIfOthersCouldNotWriteToIt(t *testing.T) {
	for _, c := range []struct {
		mode    os.FileMode
		trusted bool
	}{
		{0o755, true},
		{0o750, true},
		{0o700, true},
		{0o777, false},
		{0o775, false}, // the group could write
		{0o757, false}, // everyone else could
		{0o770, false},
		{0o777 | os.ModeSticky, false}, // as /tmp is
	} {
		// A device list: what an agent leaves in its folder, and what someone
		// else puts there to be taken for a paired phone.
		path := folderWith(t, "devices.json")
		if err := os.Chmod(path, c.mode); err != nil {
			t.Fatal(err)
		}
		held, before := holds(t, path), statFolder(t, path)
		_, err := Open(path)
		after := statFolder(t, path)
		if c.trusted {
			if err != nil {
				t.Errorf("%v: a folder that only its owner could write to was refused: %v", before.Mode(), err)
			} else if after.Mode().Perm() != 0o700 {
				t.Errorf("%v: the mode is %v afterwards, want 0700", before.Mode(), after.Mode().Perm())
			}
			continue
		}
		if err == nil {
			t.Errorf("%v: a folder that others could write to was accepted with the device list in it", before.Mode())
			continue
		}
		for _, want := range []string{path, "other users could write", `"devices.json"`, "empty the folder", "AGENT_DATA"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("%v: the error does not say %s: %v", before.Mode(), want, err)
			}
		}
		if strings.Contains(err.Error(), "\n") {
			t.Errorf("%v: the error is more than one line: %q", before.Mode(), err)
		}
		// The folder is as it was: its mode, what it holds, and when it was
		// last written to.
		if after.Mode() != before.Mode() {
			t.Errorf("the mode of the refused folder is now %v, it was %v", after.Mode(), before.Mode())
		}
		if now := holds(t, path); strings.Join(now, "\n") != strings.Join(held, "\n") {
			t.Errorf("%v: the refused folder holds %v, it held %v", before.Mode(), now, held)
		}
		if got, err := os.ReadFile(filepath.Join(path, "devices.json")); err != nil || string(got) != "devices.json" {
			t.Errorf("%v: the device list in the refused folder was changed: %q, %v", before.Mode(), got, err)
		}
		if !after.ModTime().Equal(before.ModTime()) {
			t.Errorf("%v: something was written into the refused folder", before.Mode())
		}
	}
}

func TestOpenTakesAnEmptyFolderThatOthersCouldWriteToAndMakesItPrivate(t *testing.T) {
	for _, c := range []struct {
		mode  os.FileMode
		holds []string
	}{
		{0o777, nil},
		{0o775, nil},
		{0o777 | os.ModeSticky, nil},
		// What a freshly formatted disk comes with does not count.
		{0o777, []string{"lost+found/"}},
	} {
		path := folderWith(t, c.holds...)
		if err := os.Chmod(path, c.mode); err != nil {
			t.Fatal(err)
		}
		held, before := holds(t, path), statFolder(t, path)
		if _, err := Open(path); err != nil {
			t.Errorf("%v, holding %v: refused: %v", before.Mode(), held, err)
			continue
		}
		if after := statFolder(t, path); after.Mode().Perm() != 0o700 || after.Mode()&os.ModeSticky != 0 {
			t.Errorf("%v: the mode is %v afterwards, want drwx------", before.Mode(), after.Mode())
		}
		if now := holds(t, path); strings.Join(now, "\n") != strings.Join(held, "\n") {
			t.Errorf("%v: the folder holds %v afterwards, it held %v", before.Mode(), now, held)
		}
	}
}
