package library

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/GabrielHollberg/soundstorm/internal/media"
)

// Fuzzing what the library reads from files and paths:
// go test -fuzz=FuzzCleanRelPath ./internal/library.

// Whatever a path says, what comes back is a plain relative path of
// ordinary segments, or an error: never absolute, never climbing out.
func FuzzCleanRelPath(f *testing.F) {
	for _, p := range []string{"Artist/Album/01 Song.mp3", "../../etc/passwd.mp3", `..\..\x`, "C:/Windows/x", "/abs", "a/./b", "a/.../b", ". ./x", "a/\x00b", "Ünïcødé/ﬁle.flac"} {
		f.Add(p)
	}
	f.Fuzz(func(t *testing.T, raw string) {
		out, err := cleanRelPath(raw)
		if err != nil {
			return
		}
		if out == "" || strings.HasPrefix(out, "/") || strings.Contains(out, "\\") || filepath.IsAbs(out) {
			t.Fatalf("%q became %q", raw, out)
		}
		for _, seg := range strings.Split(out, "/") {
			if seg == "" || seg == "." || seg == ".." || strings.Trim(seg, ". ") == "" {
				t.Fatalf("%q became %q, with segment %q", raw, out, seg)
			}
		}
		root := t.TempDir()
		if !strings.HasPrefix(filepath.Join(root, out), root+string(filepath.Separator)) {
			t.Fatalf("%q leaves the folder as %q", raw, out)
		}
	})
}

// A tag value names one folder, whatever it holds.
func FuzzTagSegment(f *testing.F) {
	f.Add("AC/DC Live")
	f.Add("../../etc")
	f.Fuzz(func(t *testing.T, v string) {
		seg := tagSegment(v, "Unknown")
		if seg == "" || strings.ContainsAny(seg, "/\\") || seg == "." || seg == ".." {
			t.Fatalf("%q became segment %q", v, seg)
		}
	})
}

func FuzzReadTraits(f *testing.F) {
	f.Add([]byte("\xff\xd8\xff\xe1\x00\x10Exif\x00\x00II*\x00\x08\x00\x00\x00\xff\xd9"))
	f.Add([]byte("\x00\x00\x00\x18ftypisom\x00\x00\x00\x00isommp42\x00\x00\x00\x08moov"))
	f.Add([]byte("ID3\x03\x00\x00\x00\x00\x00\x00\xff\xfb\x90\x00"))
	f.Fuzz(func(t *testing.T, data []byte) {
		withinTime(t, 3*time.Second, func() {
			for _, k := range []media.Kind{media.KindPicture, media.KindVideo, media.KindTV, media.KindMusic, media.KindAudiobook, media.KindEbook} {
				_ = ReadTraits(k, bytes.NewReader(data), int64(len(data)))
			}
		})
	})
}

// The audio fingerprint behind "already in your library".
func FuzzFingerprint(f *testing.F) {
	f.Add([]byte("ID3\x03\x00\x00\x00\x00\x00\x00\xff\xfb\x90\x00abc"), ".mp3")
	f.Add([]byte("\x00\x00\x00\x10mdatabcdefgh\x00\x00\x00\x08moov"), ".m4a")
	f.Add([]byte("fLaC\x80\x00\x00\x04abcd"), ".flac")
	f.Fuzz(func(t *testing.T, data []byte, ext string) {
		p := filepath.Join(t.TempDir(), "x")
		if err := os.WriteFile(p, data, 0o600); err != nil {
			t.Skip()
		}
		withinTime(t, 3*time.Second, func() {
			_, _, _ = fingerprint(p, ext)
			_, _ = spanLength(p)
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
