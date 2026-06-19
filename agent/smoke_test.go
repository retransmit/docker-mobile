package agent

import "testing"

// TestSmoke proves the module compiles and `go test ./...` runs in CI.
func TestSmoke(t *testing.T) {
	if 1+1 != 2 {
		t.Fatal("arithmetic is broken")
	}
}
