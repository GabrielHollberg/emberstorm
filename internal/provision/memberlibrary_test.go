package provision

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/GabrielHollberg/soundstorm/internal/httpx"
)

// A member's photo account signed in to again (its backend set up again, the
// account still there) keeps its library rather than getting a second one.
func TestAPhotoAccountSignedInAgainKeepsItsLibrary(t *testing.T) {
	var made atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPost && r.URL.Path == "/api/admin/users":
			w.WriteHeader(http.StatusBadRequest) // the email is taken
		case r.URL.Path == "/api/auth/login":
			json.NewEncoder(w).Encode(map[string]string{"accessToken": "t", "userId": "u-sam"})
		case r.URL.Path == "/api/api-keys":
			json.NewEncoder(w).Encode(map[string]string{"secret": "new-key"})
		case r.Method == http.MethodGet && r.URL.Path == "/api/libraries":
			json.NewEncoder(w).Encode([]map[string]any{
				{"id": "other", "ownerId": "u-alex", "importPaths": []string{"/pictures/Personal/sam"}},
				{"id": "sams", "ownerId": "u-sam", "importPaths": []string{"/pictures/Personal/sam"}},
			})
		case r.Method == http.MethodPost && r.URL.Path == "/api/libraries":
			made.Add(1)
			json.NewEncoder(w).Encode(map[string]string{"id": "second"})
		default:
			w.WriteHeader(http.StatusOK)
		}
	}))
	defer srv.Close()
	c, err := httpx.New(srv.URL, 5*time.Second)
	if err != nil {
		t.Fatal(err)
	}
	kept := func(string) (string, bool, error) { return "sams-pass", true, nil }
	id, err := createImmichMember(context.Background(), c, kept, "admin", "sam", "Sam", "/pictures/Personal/sam")
	if err != nil {
		t.Fatal(err)
	}
	if id.LibraryID != "sams" || made.Load() != 0 || id.Token != "new-key" {
		t.Errorf("library %q, %d made, key %q: want sam's own, none made", id.LibraryID, made.Load(), id.Token)
	}
}
