package flac

import (
	"bytes"
	"os"
	"testing"
	"time"
)

// Fuzzing the FLAC decoder: go test -fuzz=FuzzDecode ./internal/flac.
// Songs reach it converted by Navidrome, but a song's own bytes are
// anybody's.

func FuzzDecode(f *testing.F) {
	if seed, err := os.ReadFile("testdata/t16.flac"); err == nil {
		f.Add(seed)
	}
	f.Add([]byte("fLaC\x80\x00\x00\x22" + string(make([]byte, 34))))
	f.Fuzz(func(t *testing.T, data []byte) {
		withinTime(t, 5*time.Second, func() {
			total := 0
			_, _ = Decode(bytes.NewReader(data), func(info Info, channels [][]int32) error {
				for _, c := range channels {
					total += len(c)
				}
				return nil
			})
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
