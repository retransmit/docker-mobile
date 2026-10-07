//go:build unix

package state

import (
	"fmt"
	"io/fs"
	"os"
	"syscall"
)

// checkOwner refuses a folder that belongs to someone other than the user
// the agent runs as. info is what Stat says about the folder at path.
func checkOwner(path string, info fs.FileInfo) error {
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return fmt.Errorf("state folder %s: the system does not say who it belongs to", path)
	}
	return sameUser(path, stat.Uid, uint32(os.Geteuid()))
}
