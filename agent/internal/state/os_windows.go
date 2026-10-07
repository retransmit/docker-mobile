//go:build windows

package state

import "io/fs"

// checkOwner accepts every folder: Windows has no user id that the owner of
// a folder could be compared with.
func checkOwner(string, fs.FileInfo) error { return nil }

// othersCanWrite always says no: the mode that Windows reports for a folder
// says nothing about who may write to it.
func othersCanWrite(fs.FileInfo) bool { return false }
