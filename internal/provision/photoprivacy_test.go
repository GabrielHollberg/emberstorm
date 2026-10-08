package provision

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"slices"
	"testing"

	"github.com/GabrielHollberg/soundstorm/internal/state"
)

// The owner's photo library leaves out exactly the folders asked, as
// patterns no name can turn into wildcards, keeping Immich's own defaults,
// and changes nothing (no scan) when they already match.
func TestOthersPhotosAreLeftOutOfTheOwnersLibrary(t *testing.T) {
	patterns := []string{"**/@eaDir/**", "/pictures/Personal/gone/**"}
	puts, scans := 0, 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodGet:
			_ = json.NewEncoder(w).Encode(map[string]any{"exclusionPatterns": patterns})
		case r.Method == http.MethodPut:
			puts++
			var body struct {
				ExclusionPatterns []string `json:"exclusionPatterns"`
			}
			b, _ := io.ReadAll(r.Body)
			_ = json.Unmarshal(b, &body)
			patterns = body.ExclusionPatterns
			w.Write([]byte(`{}`))
		case r.Method == http.MethodPost:
			scans++
			w.WriteHeader(http.StatusNoContent)
		}
	}))
	defer srv.Close()

	want := []string{"/pictures/" + globEscape("Personal/[Mom]") + "/**", "/pictures/Personal/alice/**"}
	slices.Sort(want)
	changed, err := setExclusions(t.Context(), srv.URL, "key", "lib", "/pictures", want)
	if err != nil || !changed {
		t.Fatalf("changed %v, err %v", changed, err)
	}
	if !slices.Contains(patterns, "**/@eaDir/**") || slices.Contains(patterns, "/pictures/Personal/gone/**") || len(patterns) != 3 {
		t.Fatalf("patterns: %v", patterns)
	}
	if !slices.Contains(patterns, `/pictures/Personal/\[Mom\]/**`) {
		t.Fatalf("a name with brackets became a pattern: %v", patterns)
	}
	if puts != 1 || scans != 1 {
		t.Fatalf("puts %d scans %d", puts, scans)
	}
	// Again with the same: nothing written, no scan.
	if changed, _ := setExclusions(t.Context(), srv.URL, "key", "lib", "/pictures", want); changed || puts != 1 || scans != 1 {
		t.Fatalf("changed again: %v, puts %d scans %d", changed, puts, scans)
	}
}

// Photos go into a member's folder only once the owner's photo library is
// known to leave it out: a library that cannot be told holds them back.
func TestAMembersFolderWaitsForThePhotoLibrary(t *testing.T) {
	refuse := true
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if refuse {
			w.WriteHeader(http.StatusServiceUnavailable)
			return
		}
		if r.Method == http.MethodGet {
			_ = json.NewEncoder(w).Encode(map[string]any{"exclusionPatterns": []string{}})
			return
		}
		w.Write([]byte(`{}`))
	}))
	defer srv.Close()
	store, err := state.Open(filepath.Join(t.TempDir(), "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	store.AddUser(state.User{ID: "o", Name: "gabe"})
	store.AddUser(state.User{ID: "a", Name: "alice"})
	store.SetBackend("immich", state.Backend{Type: "immich", BaseURL: srv.URL, Token: "k", LibraryID: "lib"})
	quiet := slog.New(slog.NewTextHandler(io.Discard, nil))
	m := New(store, nil, quiet, []Target{{ID: "immich", Type: "immich", MediaPath: "/pictures"}})
	m.PhotoFolder = func(id string) (string, error) {
		u, _ := store.User(id)
		return "Personal/" + u.Name, nil
	}
	if err := m.PhotoFolderPrivate(t.Context(), "Personal/alice"); err == nil {
		t.Fatal("a member's folder was let in while the photo library refused")
	}
	if err := m.PhotoFolderPrivate(t.Context(), "Personal/gabe"); err != nil {
		t.Fatalf("the owner's own folder: %v", err)
	}
	refuse = false
	if err := m.PhotoFolderPrivate(t.Context(), "Personal/alice"); err != nil {
		t.Fatalf("once the library answered: %v", err)
	}
}
