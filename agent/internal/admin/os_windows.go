//go:build windows

package admin

import (
	"os"
	"syscall"
)

// Two error codes of Windows that package syscall does not name.
const (
	// sharingViolation is ERROR_SHARING_VIOLATION: the file is open
	// elsewhere in a way that rules this open out.
	sharingViolation = syscall.Errno(32)
	// connRefused is WSAECONNREFUSED, what connecting to a socket nobody
	// listens on fails with. The ECONNREFUSED that package syscall has for
	// Windows is a value of its own making and does not match it.
	connRefused = syscall.Errno(10061)
)

// lockFile opens the file at path, creating it if needed, and shares it with
// nobody: while it is open no other open of the file succeeds, in this
// process or in another. That is the lock. It goes when the file is closed,
// and Windows closes the file when the process ends, however it ends. A file
// that is open elsewhere is errLocked.
func lockFile(path string) (*os.File, error) {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	// Share mode 0 only keeps others out when this open asks for access
	// itself: an open that asks for none conflicts with nothing.
	h, err := syscall.CreateFile(name, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil,
		syscall.OPEN_ALWAYS, syscall.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		if err == sharingViolation {
			return nil, errLocked
		}
		return nil, &os.PathError{Op: "open", Path: path, Err: err}
	}
	return os.NewFile(uintptr(h), path), nil
}
