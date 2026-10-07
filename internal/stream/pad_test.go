package stream

import (
	"bytes"
	"testing"
)

// A converted song announced bigger than it came is finished with zeros, so
// the player is never left waiting; a big shortfall is a real failure and is
// left alone.
func TestAShortConversionIsFinished(t *testing.T) {
	var b bytes.Buffer
	if !padConverted(&b, 553451, 540552) || b.Len() != 553451-540552 {
		t.Fatalf("padded %d bytes, want %d", b.Len(), 553451-540552)
	}
	if bytes.IndexFunc(b.Bytes(), func(r rune) bool { return r != 0 }) >= 0 {
		t.Error("the padding is not all zeros")
	}
	for _, c := range [][2]int64{{0, 10}, {1000, 1000}, {1000, 700}, {-1, 5}} {
		var b bytes.Buffer
		if padConverted(&b, c[0], c[1]) || b.Len() != 0 {
			t.Errorf("want %d sent %d: padded %d", c[0], c[1], b.Len())
		}
	}
}
