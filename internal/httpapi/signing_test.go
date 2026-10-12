package httpapi

import (
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// testSigningDir, when set, is the developer's signing folder (signing.go).
var testSigningDir string

// Releases waiting to be signed: only on the developer's install, only for
// its owner, and a signature that is not the release key's is refused and
// not kept.
func TestReleasesWaitForTheSigningApp(t *testing.T) {
	h := newHarness(t)
	h.signUp(t)
	if resp, _ := h.do(t, http.MethodGet, "/api/signing", ""); resp.StatusCode != http.StatusNotFound {
		t.Fatalf("an install without signing answered %d", resp.StatusCode)
	}

	testSigningDir = t.TempDir()
	defer func() { testSigningDir = "" }()
	dir := filepath.Join(testSigningDir, "box-2026101102")
	os.MkdirAll(dir, 0o700)
	manifest := []byte(`{"serial":2026101102,"version":"2026.10.11.2"}`)
	os.WriteFile(filepath.Join(dir, "manifest.json"), manifest, 0o600)

	h = newHarness(t)
	h.signUp(t)
	h.addMember(t, "sam", "violet tractor glacier")
	sam := h.asUser(t, "sam", "violet tractor glacier")
	if resp, _ := sam.do(t, http.MethodGet, "/api/signing", ""); resp.StatusCode < 400 {
		t.Fatal("a member saw what waits to be signed")
	}
	resp, body := h.do(t, http.MethodGet, "/api/signing", "")
	var got struct {
		Items []struct{ Name, File, Data string }
	}
	json.Unmarshal(body, &got)
	if resp.StatusCode != http.StatusOK || len(got.Items) != 1 || got.Items[0].Name != "box-2026101102" || got.Items[0].File != "manifest.json" {
		t.Fatalf("waiting: %d %s", resp.StatusCode, body)
	}
	if data, _ := base64.StdEncoding.DecodeString(got.Items[0].Data); string(data) != string(manifest) {
		t.Fatalf("the bytes handed out are not the file's: %q", data)
	}
	wrong := base64.StdEncoding.EncodeToString([]byte(strings.Repeat("x", 64)))
	if resp, body := h.do(t, http.MethodPut, "/api/signing/box-2026101102", `{"signature":"`+wrong+`"}`); resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("a signature not the release key's answered %d %s", resp.StatusCode, body)
	}
	if _, err := os.Stat(filepath.Join(dir, "manifest.json.sig")); err == nil {
		t.Fatal("a wrong signature was kept")
	}
	if resp, _ := h.do(t, http.MethodPut, "/api/signing/..", `{"signature":"`+wrong+`"}`); resp.StatusCode < 400 {
		t.Fatal("a name climbing out was taken")
	}
}
