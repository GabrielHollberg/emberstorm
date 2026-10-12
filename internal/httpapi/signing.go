package httpapi

import (
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/GabrielHollberg/soundstorm/internal/desktoprelease"
)

// Releases waiting to be signed, for the developer's signing app on their
// phone (signer/ in android/, 2026-10-11: the owner signing away from home,
// the YubiKey held to the phone). On the developer's own install only
// (SOUNDSTORM_SIGNING, as the looks' training is), for the owner only.
//
// A release made on the PC (box/release.sh's manifest.json, or
// scripts/desktop-release.sh's desktop.json) is put in SigningDir/<name>/
// (docker cp); the phone reads it, shows what it says, has the YubiKey sign
// those very bytes, and hands the signature back - checked here against the
// release keys before it is kept beside the file, as yubikey.py writes it.
// The key never leaves the YubiKey; this only carries the bytes both ways.
//
//	GET /api/signing              what waits: {items: [{name, file, data (base64)}]}
//	PUT /api/signing/{name}       {signature (base64)}: kept once it checks

var signingName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

// signingFile is the release file in a waiting folder, if there is one.
func signingFile(dir string) string {
	for _, f := range []string{"manifest.json", "desktop.json"} {
		if info, err := os.Stat(filepath.Join(dir, f)); err == nil && info.Mode().IsRegular() && info.Size() <= 1<<20 {
			return f
		}
	}
	return ""
}

// GET /api/signing
func (s *Server) handleSigning(w http.ResponseWriter, r *http.Request) {
	if s.signingDir == "" {
		http.NotFound(w, r)
		return
	}
	entries, _ := os.ReadDir(s.signingDir)
	items := []map[string]any{}
	for _, e := range entries {
		if !e.IsDir() || !signingName.MatchString(e.Name()) {
			continue
		}
		dir := filepath.Join(s.signingDir, e.Name())
		file := signingFile(dir)
		if file == "" {
			continue
		}
		if _, err := os.Stat(filepath.Join(dir, file+".sig")); err == nil {
			continue // signed already
		}
		data, err := os.ReadFile(filepath.Join(dir, file))
		if err != nil {
			continue
		}
		items = append(items, map[string]any{
			"name": e.Name(),
			"file": file,
			"data": base64.StdEncoding.EncodeToString(data),
		})
	}
	sort.Slice(items, func(i, j int) bool { return items[i]["name"].(string) < items[j]["name"].(string) })
	writeJSON(w, http.StatusOK, map[string]any{"items": items})
}

// PUT /api/signing/{name}
func (s *Server) handleSigningSign(w http.ResponseWriter, r *http.Request) {
	if s.signingDir == "" {
		http.NotFound(w, r)
		return
	}
	name := r.PathValue("name")
	if !signingName.MatchString(name) {
		writeError(w, http.StatusBadRequest, "no such release")
		return
	}
	dir := filepath.Join(s.signingDir, name)
	file := signingFile(dir)
	if file == "" {
		writeError(w, http.StatusNotFound, "no such release")
		return
	}
	var body struct {
		Signature string `json:"signature"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "expected a signature")
		return
	}
	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(body.Signature))
	if err != nil || len(sig) != ed25519.SignatureSize {
		writeError(w, http.StatusBadRequest, "That is not a signature.")
		return
	}
	data, err := os.ReadFile(filepath.Join(dir, file))
	if err != nil {
		writeError(w, http.StatusNotFound, "no such release")
		return
	}
	keys, err := desktoprelease.Keys()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "The release keys could not be read.")
		return
	}
	ok := false
	for _, k := range keys {
		if ed25519.Verify(k, data, sig) {
			ok = true
			break
		}
	}
	if !ok {
		writeError(w, http.StatusBadRequest, "The signature does not match EmberStorm's release keys - was it the right YubiKey?")
		return
	}
	out := base64.StdEncoding.EncodeToString(sig) + "\n"
	if err := os.WriteFile(filepath.Join(dir, file+".sig"), []byte(out), 0o644); err != nil {
		writeError(w, http.StatusInternalServerError, "The signature could not be kept.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"signed": true})
}
