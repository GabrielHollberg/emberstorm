package mp4hls

import (
	"bytes"
	"io"
	"os"
	"testing"
	"time"
)

// Fuzzing the long-audiobook remuxer: go test -fuzz=FuzzParse ./internal/mp4hls.
// A book's index is anybody's bytes.

func FuzzParse(f *testing.F) {
	if file, err := os.ReadFile("testdata/short.m4b"); err == nil {
		if n, err := Layout("testdata/short.m4b"); err == nil {
			at := bytes.LastIndex(file, []byte("moov"))
			f.Add(file[at+4:at-4+int(n)], int64(len(file)))
		}
	}
	f.Fuzz(func(t *testing.T, moov []byte, size int64) {
		withinTime(t, 5*time.Second, func() {
			b, err := parse(moov, size)
			if err != nil {
				return
			}
			b.path = "testdata/short.m4b"
			_ = b.Playlist()
			_ = b.Duration()
			for i := 0; i < b.Segments() && i < 3; i++ {
				_ = b.WriteSegment(io.Discard, i)
			}
		})
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
