package desktoprelease

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestTheBuiltInKeysAreTheBoxs(t *testing.T) {
	box, err := os.ReadFile("../../box/release.pub")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(bytes.ReplaceAll(box, []byte("\r"), nil), bytes.ReplaceAll(releaseKeys, []byte("\r"), nil)) {
		t.Fatal("internal/desktoprelease/release.pub differs from box/release.pub: copy it over")
	}
	keys, err := Keys()
	if err != nil || len(keys) != 2 {
		t.Fatalf("keys: %v %d", err, len(keys))
	}
}

func signed(t *testing.T, m Manifest, priv ed25519.PrivateKey) ([]byte, []byte) {
	t.Helper()
	data, _ := json.Marshal(m)
	return data, []byte(base64.StdEncoding.EncodeToString(ed25519.Sign(priv, data)) + "\n")
}

func sum(b []byte) string { s := sha256.Sum256(b); return hex.EncodeToString(s[:]) }

func TestOnlyASignedWholeDesktopReleaseIsTaken(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	keys := []ed25519.PublicKey{pub}
	script := []byte("Write-Host hi")
	good := Manifest{
		Kind: Kind, Version: "0.13.0", Serial: 13,
		Commit: strings.Repeat("a", 40),
		Image:  "ghcr.io/gabrielhollberg/soundstorm@sha256:" + strings.Repeat("b", 64),
		Files: map[string]File{
			"install.ps1":        {SHA256: sum(script), Size: int64(len(script))},
			"install.sh":         {SHA256: strings.Repeat("c", 64), Size: 10},
			"docker-compose.yml": {SHA256: strings.Repeat("d", 64), Size: 10},
		},
	}
	data, sig := signed(t, good, priv)
	m, err := Verify(data, sig, keys)
	if err != nil {
		t.Fatal(err)
	}
	if err := m.Check("install.ps1", script); err != nil {
		t.Fatal(err)
	}
	if m.Check("install.ps1", []byte("Write-Host evil")) == nil {
		t.Fatal("a changed script was taken")
	}
	// Changed by one byte, or signed by another key.
	bad := bytes.Replace(data, []byte("0.13.0"), []byte("0.13.1"), 1)
	if _, err := Verify(bad, sig, keys); err == nil {
		t.Fatal("a changed list was taken")
	}
	data2, sig2 := signed(t, good, other)
	if _, err := Verify(data2, sig2, keys); err == nil {
		t.Fatal("another key's signature was taken")
	}
	// Signed, but not a desktop release, or not whole.
	for _, change := range []func(*Manifest){
		func(m *Manifest) { m.Kind = "" },
		func(m *Manifest) { m.Image = "ghcr.io/gabrielhollberg/soundstorm:latest" },
		func(m *Manifest) { delete(m.Files, "docker-compose.yml") },
		func(m *Manifest) { m.Files["../evil.ps1"] = File{SHA256: strings.Repeat("e", 64), Size: 1} },
	} {
		copied := good
		copied.Files = map[string]File{}
		for k, v := range good.Files {
			copied.Files[k] = v
		}
		change(&copied)
		d, s := signed(t, copied, priv)
		if _, err := Verify(d, s, keys); err == nil {
			t.Fatalf("an unfit release was taken: %+v", copied)
		}
	}
}

func TestFetchWritesOnlyACheckedRelease(t *testing.T) {
	pub, priv, _ := ed25519.GenerateKey(rand.Reader)
	files := map[string][]byte{
		"install.ps1":        []byte("Write-Host install"),
		"install.sh":         []byte("echo install"),
		"docker-compose.yml": []byte("services: {}"),
	}
	m := Manifest{
		Kind: Kind, Version: "0.13.0", Serial: 13,
		Commit: strings.Repeat("a", 40),
		Image:  "ghcr.io/gabrielhollberg/soundstorm@sha256:" + strings.Repeat("b", 64),
		Files:  map[string]File{},
	}
	for name, b := range files {
		m.Files[name] = File{SHA256: sum(b), Size: int64(len(b))}
	}
	data, sig := signed(t, m, priv)
	served := map[string][]byte{"desktop.json": data, "desktop.json.sig": sig}
	for k, v := range files {
		served[k] = v
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, ok := served[strings.TrimPrefix(r.URL.Path, "/")]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Write(b)
	}))
	defer srv.Close()
	dir := filepath.Join(t.TempDir(), "release")

	got, err := Fetch(srv.URL+"/", dir, []ed25519.PublicKey{pub}, Get)
	if err != nil || got.Serial != 13 {
		t.Fatalf("a good release: %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(dir, "install.ps1")); string(b) != "Write-Host install" {
		t.Fatalf("install.ps1 written as %q", b)
	}

	// A file changed on the server: nothing is written, the folder is not
	// replaced.
	served["install.ps1"] = []byte("Write-Host evil!!!")
	os.RemoveAll(dir)
	if _, err := Fetch(srv.URL+"/", dir, []ed25519.PublicKey{pub}, Get); err == nil {
		t.Fatal("a changed install.ps1 was taken")
	}
	if _, err := os.Stat(dir); err == nil {
		t.Fatal("something was written for a release that failed its check")
	}

	// The list changed and re-signed by another key.
	served["install.ps1"] = files["install.ps1"]
	_, other, _ := ed25519.GenerateKey(rand.Reader)
	served["desktop.json"], served["desktop.json.sig"] = signed(t, m, other)
	if _, err := Fetch(srv.URL+"/", dir, []ed25519.PublicKey{pub}, Get); err == nil {
		t.Fatal("a list signed by another key was taken")
	}
}

// The Mac app checks releases with the same keys, written into its source
// (mac/EmberStorm/SignedRelease.swift): kept the same as box/release.pub.
func TestTheMacAppHasTheReleaseKeys(t *testing.T) {
	box, err := os.ReadFile("../../box/release.pub")
	if err != nil {
		t.Skip("no box/release.pub here")
	}
	swift, err := os.ReadFile("../../mac/EmberStorm/SignedRelease.swift")
	if err != nil {
		t.Skip("no Mac app here")
	}
	want, err := ParseKeys(box)
	if err != nil {
		t.Fatal(err)
	}
	// A Windows checkout writes it with CRLF.
	src := strings.ReplaceAll(string(swift), "\r\n", "\n")
	start := strings.Index(src, "static let keys: [String] = [")
	end := strings.Index(src[start:], "]\n")
	if start < 0 || end < 0 {
		t.Fatal("no keys in SignedRelease.swift")
	}
	var got []string
	for _, line := range strings.Split(src[start:start+end], "\n")[1:] {
		line = strings.Trim(strings.TrimSpace(line), `",`)
		if line != "" {
			got = append(got, line)
		}
	}
	if len(got) != len(want) {
		t.Fatalf("the Mac app has %d release keys, box/release.pub %d: copy them over", len(got), len(want))
	}
	for i, k := range want {
		if got[i] != base64.StdEncoding.EncodeToString(k) {
			t.Fatalf("the Mac app's release key %d differs from box/release.pub: copy them over", i+1)
		}
	}
}

// The Linux updater install.sh leaves on a machine (emberstorm-update.sh)
// checks releases with the same keys, written into install.sh: kept the same
// as box/release.pub.
func TestTheLinuxUpdaterHasTheReleaseKeys(t *testing.T) {
	box, err := os.ReadFile("../../box/release.pub")
	if err != nil {
		t.Skip("no box/release.pub here")
	}
	sh, err := os.ReadFile("../../install.sh")
	if err != nil {
		t.Skip("no install.sh here")
	}
	want, err := ParseKeys(box)
	if err != nil {
		t.Fatal(err)
	}
	src := strings.ReplaceAll(string(sh), "\r\n", "\n")
	start := strings.Index(src, "KEYS='\n")
	if start < 0 {
		t.Fatal("no keys in install.sh's updater")
	}
	end := strings.Index(src[start+len("KEYS='\n"):], "'\n")
	var got []string
	for _, line := range strings.Split(src[start+len("KEYS='\n"):start+len("KEYS='\n")+end], "\n") {
		if line = strings.TrimSpace(line); line != "" {
			got = append(got, line)
		}
	}
	if len(got) != len(want) {
		t.Fatalf("install.sh's updater has %d release keys, box/release.pub %d: copy them over", len(got), len(want))
	}
	for i, k := range want {
		if got[i] != base64.StdEncoding.EncodeToString(k) {
			t.Fatalf("install.sh's updater's release key %d differs from box/release.pub: copy them over", i+1)
		}
	}
}
