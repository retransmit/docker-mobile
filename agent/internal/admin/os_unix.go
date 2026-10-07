//go:build unix

package admin

import (
	"os"
	"syscall"
)

// connRefused is what connecting to a socket nobody listens on fails with.
const connRefused = syscall.ECONNREFUSED

// lockFile opens the file at path, creating it if needed, and takes an
// exclusive lock on it without waiting. The lock goes when the file is
// closed, and the kernel closes the file when the process ends, however it
// ends. A lock that another open file holds is errLocked, also when that
// file was opened by this same process.
func lockFile(path string) (*os.File, error) {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0o600)
	if err != nil {
		return nil, err
	}
	for {
		err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err != syscall.EINTR {
			break
		}
	}
	if err != nil {
		f.Close()
		if err == syscall.EWOULDBLOCK {
			return nil, errLocked
		}
		return nil, &os.PathError{Op: "lock", Path: path, Err: err}
	}
	return f, nil
}
