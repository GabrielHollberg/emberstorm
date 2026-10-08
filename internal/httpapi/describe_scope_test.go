package httpapi

import (
	"bytes"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/GabrielHollberg/soundstorm/internal/auth"
	"github.com/GabrielHollberg/soundstorm/internal/library"
	"github.com/GabrielHollberg/soundstorm/internal/media"
	"github.com/GabrielHollberg/soundstorm/internal/state"
)

// Naming a photo looks only in the asker's own folder: another member's
// file is never read, or its camera and when it was taken could be
// learnt one guess at a time (the blind security review).
func TestNamingAPhotoDoesNotLookInAnothersFolder(t *testing.T) {
	lib, err := library.Open(t.TempDir(), "./library", slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatal(err)
	}
	s := &Server{library: lib}
	describe := func(asker, dest string) string {
		body := exifJPEG("Google", "Pixel 8")
		r := httptest.NewRequest(http.MethodPost, "/api/upload/describe?kind=picture&dest="+dest+
			"&size="+strconv.Itoa(len(body))+"&head="+strconv.Itoa(len(body)), bytes.NewReader(body))
		r = r.WithContext(auth.WithUser(r.Context(), state.User{ID: asker, Name: asker, Role: state.RoleMember}))
		w := httptest.NewRecorder()
		s.handleUploadDescribe(w, r)
		var out struct{ Name string }
		_ = json.NewDecoder(w.Body).Decode(&out)
		return out.Name
	}
	for _, who := range []string{"bob", "eve"} {
		rel, err := lib.EnsurePersonalFolder(who)
		if err != nil {
			t.Fatal(err)
		}
		month := filepath.Join(lib.PathFor(media.KindPicture), filepath.FromSlash(rel), "2024", "05")
		if err := os.MkdirAll(month, 0o777); err != nil {
			t.Fatal(err)
		}
		os.WriteFile(filepath.Join(month, "IMG_0001.jpg"), exifJPEG("Apple", "iPhone 15 Pro"), 0o666)
	}
	bobs := "pictures/" + library.PersonalFolder("bob") + "/2024/05/IMG_0001.jpg"
	if got := describe("eve", bobs); got != "IMG_0001.jpg" {
		t.Fatalf("eve learnt something of bob's photo: %q", got)
	}
	eves := "pictures/" + library.PersonalFolder("eve") + "/2024/05/IMG_0001.jpg"
	if got := describe("eve", eves); got == "IMG_0001.jpg" || got == "" {
		t.Fatalf("eve's own taken name was not described: %q", got)
	}
}
