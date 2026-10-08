package stream

import (
	"testing"
	"time"
)

// Fuzzing the picture-free song header builders and range parsing:
// go test -fuzz=FuzzStripMoov ./internal/stream. A song's index is
// anybody's bytes, and a Range header anybody's text.

func FuzzStripMoov(f *testing.F) {
	f.Add([]byte("\x00\x00\x00\x6cmvhd\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x03\xe8\x00\x00\x27\x10"+
		"\x00\x00\x00\x10udta\x00\x00\x00\x08meta"+"\x00\x00\x00\x14stco\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x10\x00"), int64(100), int64(-50))
	f.Fuzz(func(t *testing.T, moov []byte, from, shift int64) {
		withinTime(t, 3*time.Second, func() {
			_ = mp4Seconds(moov)
			out, err := stripMoov(append([]byte(nil), moov...))
			if err == nil {
				_ = shiftChunkOffsets(out, from, shift)
			}
		})
	})
}

func FuzzMP3Frame(f *testing.F) {
	f.Add([]byte{0xff, 0xfb, 0x90, 0x64})
	f.Fuzz(func(t *testing.T, frame []byte) {
		withinTime(t, time.Second, func() { _ = mp3FrameKbps(frame) })
	})
}

// A satisfiable range always lies within the file.
func FuzzParseRange(f *testing.F) {
	for _, v := range []string{"bytes=0-", "bytes=100-199", "bytes=-500", "bytes=5-2", "bytes=0-0,5-9"} {
		f.Add(v, int64(1000))
	}
	f.Fuzz(func(t *testing.T, v string, size int64) {
		if size <= 0 {
			return
		}
		start, end, _, ok := parseRange(v, size)
		if ok && (start < 0 || end < start || end >= size) {
			t.Fatalf("%q of %d: %d-%d", v, size, start, end)
		}
	})
}

// withinTime fails the input when fn takes longer than d: a crafted file
// that keeps a processor busy is as much a fault as one that crashes.
func withinTime(t *testing.T, d time.Duration, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { defer close(done); fn() }()
	select {
	case <-done:
	case <-time.After(d):
		t.Fatalf("took longer than %s", d)
	}
}
