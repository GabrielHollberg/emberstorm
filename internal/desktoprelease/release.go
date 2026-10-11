// Package desktoprelease checks a signed release of EmberStorm for computers
// (Windows, Mac and Linux): the files the installers run and the compose file
// naming the images, listed with their SHA-256 in desktop.json and signed with
// the release key on its YubiKey (box/yubikey.py), as box updates are.
//
// So a change on GitHub - a stolen token, a takeover of the account - reaches
// nobody: whatever the installers download is refused unless the YubiKey
// signed it. The keys are the box's (release.pub here is box/release.pub,
// kept the same by a test), and a desktop list says what it is ("kind"), so
// it can never be taken for a box update nor a box update for it.
package desktoprelease

import (
	"crypto/ed25519"
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

// Kind is what a desktop list says it is.
const Kind = "emberstorm-desktop"

// The release keys: the release key's YubiKey first, then the backup's.
//
//go:embed release.pub
var releaseKeys []byte

// File is one file of a release.
type File struct {
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

// Manifest is desktop.json.
type Manifest struct {
	Kind    string          `json:"kind"`
	Version string          `json:"version"`
	Serial  int64           `json:"serial"`
	Commit  string          `json:"commit"`
	Image   string          `json:"image"`
	Created string          `json:"created"`
	Files   map[string]File `json:"files"`
}

// Needed are the files every release carries.
var Needed = []string{"install.ps1", "install.sh", "docker-compose.yml"}

var (
	nameRe    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)
	hexRe     = regexp.MustCompile(`^[0-9a-f]{64}$`)
	versionRe = regexp.MustCompile(`^[0-9]+\.[0-9]+(\.[0-9]+)?$`)
	commitRe  = regexp.MustCompile(`^[0-9a-f]{40}$`)
	imageRe   = regexp.MustCompile(`^ghcr\.io/gabrielhollberg/soundstorm@sha256:[0-9a-f]{64}$`)
)

// Keys are the release keys built in.
func Keys() ([]ed25519.PublicKey, error) {
	return ParseKeys(releaseKeys)
}

// ParseKeys reads release.pub: a base64 key a line, # for notes.
func ParseKeys(text []byte) ([]ed25519.PublicKey, error) {
	var keys []ed25519.PublicKey
	for _, line := range strings.Split(string(text), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		raw, err := base64.StdEncoding.DecodeString(line)
		if err != nil || len(raw) != ed25519.PublicKeySize {
			return nil, errors.New("release keys: a line is not a key")
		}
		keys = append(keys, ed25519.PublicKey(raw))
	}
	if len(keys) == 0 {
		return nil, errors.New("release keys: none")
	}
	return keys, nil
}

// Verify checks desktop.json against its signature (desktop.json.sig, base64,
// as yubikey.py writes it) and any of keys, and that it is a whole desktop
// release.
func Verify(data, sig []byte, keys []ed25519.PublicKey) (*Manifest, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(sig)))
	if err != nil || len(raw) != ed25519.SignatureSize {
		return nil, errors.New("the release's signature cannot be read")
	}
	signed := false
	for _, k := range keys {
		if len(k) == ed25519.PublicKeySize && ed25519.Verify(k, data, raw) {
			signed = true
			break
		}
	}
	if !signed {
		return nil, errors.New("the release is not signed by EmberStorm's release key")
	}
	var m Manifest
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("the release's list cannot be read: %w", err)
	}
	if err := m.Validate(); err != nil {
		return nil, err
	}
	return &m, nil
}

// Validate checks a list is a desktop release with every file it needs.
func (m *Manifest) Validate() error {
	if m.Kind != Kind {
		return errors.New("the signed list is not a desktop release")
	}
	if !versionRe.MatchString(m.Version) || m.Serial <= 0 {
		return errors.New("the release has no version")
	}
	if !commitRe.MatchString(m.Commit) || !imageRe.MatchString(m.Image) {
		return errors.New("the release does not name its commit and image")
	}
	if len(m.Files) > 16 {
		return errors.New("the release lists too many files")
	}
	for name, f := range m.Files {
		if !nameRe.MatchString(name) || strings.Contains(name, "..") {
			return fmt.Errorf("the release names a file it may not: %q", name)
		}
		if !hexRe.MatchString(f.SHA256) || f.Size <= 0 || f.Size > 64<<20 {
			return fmt.Errorf("the release's entry for %s is not whole", name)
		}
	}
	for _, name := range Needed {
		if _, ok := m.Files[name]; !ok {
			return fmt.Errorf("the release has no %s", name)
		}
	}
	return nil
}

// Check says whether data is the file the release lists under name.
func (m *Manifest) Check(name string, data []byte) error {
	f, ok := m.Files[name]
	if !ok {
		return fmt.Errorf("%s is not in the release", name)
	}
	sum := sha256.Sum256(data)
	if int64(len(data)) != f.Size || hex.EncodeToString(sum[:]) != f.SHA256 {
		return fmt.Errorf("%s is not the file the release signed", name)
	}
	return nil
}

// Fetch downloads the signed list at base (desktop.json and
// desktop.json.sig) and every file it names, checks them all against keys,
// and only then writes them to dir, made afresh and private (0700). It
// answers the list.
func Fetch(base, dir string, keys []ed25519.PublicKey, get func(addr string, limit int64) ([]byte, error)) (*Manifest, error) {
	data, err := get(base+"desktop.json", 1<<20)
	if err != nil {
		return nil, err
	}
	sig, err := get(base+"desktop.json.sig", 4<<10)
	if err != nil {
		return nil, err
	}
	m, err := Verify(data, sig, keys)
	if err != nil {
		return nil, err
	}
	files := map[string][]byte{}
	for name, f := range m.Files {
		b, err := get(base+name, f.Size)
		if err != nil {
			return nil, err
		}
		if err := m.Check(name, b); err != nil {
			return nil, err
		}
		files[name] = b
	}
	if err := os.RemoveAll(dir); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}
	for name, b := range files {
		if err := os.WriteFile(filepath.Join(dir, name), b, 0o600); err != nil {
			return nil, err
		}
	}
	return m, nil
}

// Get fetches one address over HTTP, at most limit bytes.
func Get(addr string, limit int64) ([]byte, error) {
	client := &http.Client{Timeout: 2 * time.Minute}
	resp, err := client.Get(addr)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s answered %s", path.Base(addr), resp.Status)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, limit+1))
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > limit {
		return nil, errors.New(path.Base(addr) + " is larger than the release says")
	}
	return data, nil
}
