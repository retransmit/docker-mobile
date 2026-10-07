// Package qr draws a QR code in a terminal with half-block characters, two
// rows of modules per line of text.
package qr

import (
	"fmt"
	"io"
	"strings"

	rscqr "rsc.io/qr"
)

// quiet is the blank border, in modules, that scanners need around a code.
const quiet = 4

const (
	full  = "\u2588" // both halves
	upper = "\u2580" // upper half
	lower = "\u2584" // lower half
)

// Render writes text as a QR code to w. A module that must be light is drawn
// with the text colour and a dark one is left blank, which reads as a normal
// code on a dark terminal. invert swaps the two, for a light terminal.
func Render(w io.Writer, text string, invert bool) error {
	code, err := rscqr.Encode(text, rscqr.M)
	if err != nil {
		return fmt.Errorf("encode QR code: %w", err)
	}
	size := code.Size + 2*quiet
	// lit reports whether the module at (x, y), border included, is drawn.
	lit := func(x, y int) bool {
		if y >= size {
			return false
		}
		dark := x >= quiet && y >= quiet && x < size-quiet && y < size-quiet && code.Black(x-quiet, y-quiet)
		return dark == invert
	}
	var b strings.Builder
	for y := 0; y < size; y += 2 {
		for x := 0; x < size; x++ {
			top, bottom := lit(x, y), lit(x, y+1)
			switch {
			case top && bottom:
				b.WriteString(full)
			case top:
				b.WriteString(upper)
			case bottom:
				b.WriteString(lower)
			default:
				b.WriteByte(' ')
			}
		}
		b.WriteByte('\n')
	}
	_, err = io.WriteString(w, b.String())
	return err
}
