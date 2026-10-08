package tags

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Fuzzing the tag readers: go test -fuzz=FuzzRead ./internal/tags. A
// file's tags are anybody's bytes, read on every upload.

func FuzzRead(f *testing.F) {
	f.Add([]byte("ID3\x03\x00\x00\x00\x00\x00\x10TIT2\x00\x00\x00\x06\x00\x00\x00song"))
	f.Add([]byte("ID3\x04\x00\x80\x00\x00\x00\x10TPE1\x00\x00\x00\x06\x00\x00\x03band"))
	f.Add([]byte("fLaC\x00\x00\x00\x22" + string(make([]byte, 34))))
	f.Add([]byte("\x00\x00\x00\x18ftypM4A \x00\x00\x00\x00M4A mp42isom"))
	f.Fuzz(func(t *testing.T, data []byte) {
		withinTime(t, 3*time.Second, func() { _, _ = Read(bytes.NewReader(data)) })
	})
}

func FuzzVideo(f *testing.F) {
	f.Add([]byte("\x00\x00\x00\x18ftypqt  \x00\x00\x00\x00qt  \x00\x00\x00\x08moov"))
	f.Add([]byte("\x1aE\xdf\xa3\x93B\x82\x88matroska"))
	f.Fuzz(func(t *testing.T, data []byte) {
		p := filepath.Join(t.TempDir(), "clip.mov")
		if err := os.WriteFile(p, data, 0o600); err != nil {
			t.Skip()
		}
		withinTime(t, 3*time.Second, func() {
			_ = VideoCamera(p)
			_, _ = VideoDate(p)
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
