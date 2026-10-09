package library

import (
	"os"
	"path/filepath"
	"testing"
)

// A folder in a shelf swapped for a link is not written through.
func TestAFolderThatIsALinkIsNotWrittenThrough(t *testing.T) {
	root, outside := t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "music"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(outside, filepath.Join(root, "music", "Artist")); err != nil {
		t.Skip("no symlinks here:", err)
	}
	staged := filepath.Join(root, "part")
	os.WriteFile(staged, []byte("x"), 0o644)
	if err := placeFile(staged, filepath.Join(root, "music", "Artist", "song.mp3")); err == nil {
		t.Fatal("a file was written through a link")
	}
	if entries, _ := os.ReadDir(outside); len(entries) != 0 {
		t.Fatalf("something landed outside: %v", entries)
	}
}

// A tag naming a reserved or hidden folder is made harmless.
func TestATagCannotNameAReservedOrHiddenFolder(t *testing.T) {
	for in, want := range map[string]string{"NUL": "_NUL", "con.txt": "_con.txt", ".hidden": "hidden", "...": "Unknown"} {
		if got := tagSegment(in, "Unknown"); got != want {
			t.Errorf("tagSegment(%q) = %q, want %q", in, got, want)
		}
	}
}
