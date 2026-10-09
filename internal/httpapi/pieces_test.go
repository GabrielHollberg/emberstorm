package httpapi

import (
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// A big file sent in pieces is filed exactly as one sent whole: pieces in
// order, one sent twice told where the upload stands, and nothing left behind
// in staging (the owner's report, 2026-10-09: Firefox dropped every big
// upload part way).
func TestAFileSentInPiecesIsFiled(t *testing.T) {
	h := newHarness(t)
	h.signUp(t)

	content := "abcdefghij"
	resp, out := h.do(t, http.MethodPost, "/api/upload/pieces",
		`{"path":"Arrival (2016)/Arrival (2016).mkv","kind":"video","size":`+strconv.Itoa(len(content))+`}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("start: %d %s", resp.StatusCode, out)
	}
	var begun struct{ ID string }
	_ = json.Unmarshal(out, &begun)
	base := "/api/upload/pieces/" + begun.ID

	piece := func(offset int, s string) (int, map[string]any) {
		t.Helper()
		r, b := h.do(t, http.MethodPut, base+"?offset="+strconv.Itoa(offset), s)
		var m map[string]any
		_ = json.Unmarshal(b, &m)
		return r.StatusCode, m
	}
	if code, m := piece(0, "abcd"); code != http.StatusOK || m["received"] != float64(4) {
		t.Fatalf("first piece: %d %v", code, m)
	}
	// Sent again - its answer lost: the upload says where it stands.
	if code, m := piece(0, "abcd"); code != http.StatusConflict || m["received"] != float64(4) {
		t.Fatalf("a piece sent twice: %d %v", code, m)
	}
	if code, m := piece(4, "efg"); code != http.StatusOK || m["received"] != float64(7) {
		t.Fatalf("second piece: %d %v", code, m)
	}
	code, m := piece(7, "hij")
	if code != http.StatusOK || m["dest"] != "movies/Arrival (2016)/Arrival (2016).mkv" {
		t.Fatalf("last piece: %d %v", code, m)
	}

	root := h.libraryRoot(t)
	got, err := os.ReadFile(filepath.Join(root, "movies", "Arrival (2016)", "Arrival (2016).mkv"))
	if err != nil || string(got) != content {
		t.Fatalf("filed %q, %v; want %q", got, err, content)
	}
	if left, _ := filepath.Glob(filepath.Join(root, ".uploads", "piece-*")); len(left) != 0 {
		t.Errorf("left in staging: %v", left)
	}
	// Finished, it is gone.
	if r, _ := h.do(t, http.MethodGet, base, ""); r.StatusCode != http.StatusNotFound {
		t.Errorf("a finished upload still answers: %d", r.StatusCode)
	}
}

// Nobody else's upload can be sent to, looked at or stopped.
func TestAnUploadInPiecesIsItsOwners(t *testing.T) {
	h := newHarness(t)
	h.signUp(t)
	_, out := h.do(t, http.MethodPost, "/api/upload/pieces", `{"path":"A (2001)/A (2001).mkv","kind":"video","size":4}`)
	var begun struct{ ID string }
	_ = json.Unmarshal(out, &begun)

	if r, b := h.do(t, http.MethodPost, "/api/users", `{"username":"sam","password":"violet tractor glacier"}`); r.StatusCode != http.StatusOK {
		t.Fatalf("adding sam: %d %s", r.StatusCode, b)
	}
	other := h.another(t)
	if code, _ := signInAs(t, other, "sam", "violet tractor glacier"); code != http.StatusOK {
		t.Fatalf("sam signing in: %d", code)
	}
	for _, method := range []string{http.MethodGet, http.MethodPut} {
		r, b := other.do(t, method, "/api/upload/pieces/"+begun.ID+"?offset=0", "abcd")
		if r.StatusCode != http.StatusNotFound {
			t.Errorf("%s by somebody else: %d %s", method, r.StatusCode, b)
		}
	}
	if r, _ := h.do(t, http.MethodGet, "/api/upload/pieces/"+begun.ID, ""); r.StatusCode != http.StatusOK {
		t.Errorf("its owner's look: %d", r.StatusCode)
	}
}

// A disc's extra dropped on its own after its film goes into the film's
// extras folder, in the plan and on arrival, rather than being refused as the
// film (the owner's report, 2026-10-09).
func TestAnExtraAfterItsFilmGoesBesideIt(t *testing.T) {
	h := newHarness(t)
	h.signUp(t)
	film := strings.Repeat("f", 100)
	if r, b := h.upload(t, "video", "Film/Film_t00.mkv", film); r.StatusCode != http.StatusOK {
		t.Fatalf("the film: %d %s", r.StatusCode, b)
	}

	_, out := h.do(t, http.MethodPost, "/api/upload/plan", `{"paths":["Film/Film_t05.mkv"],"sizes":[10],"choices":{"Film":"video"}}`)
	if !strings.Contains(string(out), `"dest": "movies/Film/extras/Film - t05.mkv"`) &&
		!strings.Contains(string(out), `"dest":"movies/Film/extras/Film - t05.mkv"`) {
		t.Errorf("planned: %s", out)
	}
	// An older page sends the name it was dropped as: the server places it.
	r, b := h.upload(t, "video", "Film/Film_t05.mkv", "extra bits")
	if r.StatusCode != http.StatusOK || !strings.Contains(string(b), "movies/Film/extras/Film - t05.mkv") {
		t.Fatalf("the extra: %d %s", r.StatusCode, b)
	}
	// The film sent again is still the same film, refused as already there.
	if r, b := h.upload(t, "video", "Film/Film_t00.mkv", film); r.StatusCode != http.StatusConflict {
		t.Errorf("the film again: %d %s", r.StatusCode, b)
	}
}
