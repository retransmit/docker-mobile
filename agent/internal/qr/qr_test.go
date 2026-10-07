package qr

import (
	"bytes"
	"strings"
	"testing"

	rscqr "rsc.io/qr"
)

const link = "dockermobile://pair?c=K7QM2XPA9TRC&f=OfCPv7Bu5FeqspEEZcUtbwd9RqmtauCT2Hr78uU9WwI&h=my-server.lan&n=home+lab&p=8443&v=1"

// decode rebuilds the module grid from the rendered text.
func decode(t *testing.T, out string, invert bool) [][]bool {
	t.Helper()
	lines := strings.Split(strings.TrimRight(out, "\n"), "\n")
	var grid [][]bool
	for _, line := range lines {
		var top, bottom []bool
		for _, r := range line {
			var up, down bool
			switch string(r) {
			case full:
				up, down = true, true
			case upper:
				up = true
			case lower:
				down = true
			case " ":
			default:
				t.Fatalf("unexpected character %q", r)
			}
			// A drawn half is a light module unless inverted.
			top = append(top, up == invert)
			bottom = append(bottom, down == invert)
		}
		grid = append(grid, top, bottom)
	}
	return grid
}

func TestRenderDrawsTheCodeWithItsQuietBorder(t *testing.T) {
	for _, invert := range []bool{false, true} {
		var buf bytes.Buffer
		if err := Render(&buf, link, invert); err != nil {
			t.Fatalf("Render: %v", err)
		}
		code, err := rscqr.Encode(link, rscqr.M)
		if err != nil {
			t.Fatal(err)
		}
		grid := decode(t, buf.String(), invert)
		size := code.Size + 2*quiet
		if len(grid) < size {
			t.Fatalf("invert=%v: %d rows, want at least %d", invert, len(grid), size)
		}
		for y := 0; y < size; y++ {
			if len(grid[y]) != size {
				t.Fatalf("invert=%v: row %d has %d modules, want %d", invert, y, len(grid[y]), size)
			}
			for x := 0; x < size; x++ {
				inside := x >= quiet && y >= quiet && x < size-quiet && y < size-quiet
				want := inside && code.Black(x-quiet, y-quiet)
				if grid[y][x] != want {
					t.Fatalf("invert=%v: module (%d,%d) dark = %v, want %v", invert, x, y, grid[y][x], want)
				}
			}
		}
	}
}

func TestAPairingLinkFitsAnEightyColumnTerminal(t *testing.T) {
	var buf bytes.Buffer
	if err := Render(&buf, link, false); err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(strings.TrimRight(buf.String(), "\n"), "\n") {
		if n := len([]rune(line)); n > 80 {
			t.Fatalf("a line is %d columns wide", n)
		}
	}
}

func TestRenderRejectsTextThatDoesNotFit(t *testing.T) {
	if err := Render(&bytes.Buffer{}, strings.Repeat("x", 5000), false); err == nil {
		t.Fatal("text beyond the capacity of a QR code was accepted")
	}
}
