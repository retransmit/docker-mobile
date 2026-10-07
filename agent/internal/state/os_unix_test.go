//go:build unix

package state

import (
	"os"
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
