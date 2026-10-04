package provision

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"slices"
	"testing"
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
