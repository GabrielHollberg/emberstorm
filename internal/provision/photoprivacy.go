package provision

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"path"
	"slices"
	"strings"
	"sync"

	"github.com/GabrielHollberg/soundstorm/internal/httpx"
)

// The owner's photo library is the administrator's, reading the whole
// pictures folder - so it used to show everybody's own photos in the owner's
// app: the timeline, search, faces, places. The owner's choice (2026-10-04):
// the owner keeps the folders on disk, but sees only their own photos in the
// app, as every member does. So the owner's library leaves out every other
// person's own folder (Immich's exclusion patterns), and keeps whatever lies
// outside the personal folders - the household's shared photos.
//
// Kept in step by SyncPhotoPrivacy: when somebody is added or removed, at
// start, and every few minutes (a folder copied in by hand). Patterns this
// did not write (Immich's own defaults) are left as they are.

// SyncPhotoPrivacy brings the owner's photo library's left-out folders up to
// date: every person's own folder but the owner's, and any folder left in
// Personal/ (a removed member's, kept for the owner to decide about).
func (m *Manager) SyncPhotoPrivacy(ctx context.Context) {
	if m.PhotoFolder == nil {
		return
	}
	var owner string
	others := map[string]bool{}
	for _, u := range m.store.Users() {
		folder, err := m.PhotoFolder(u.ID)
		if err != nil || folder == "" {
			continue
		}
		if u.IsOwner() {
			owner = folder
			continue
		}
		others[folder] = true
	}
	if m.PersonalFolders != nil {
		for _, f := range m.PersonalFolders() {
			others[f] = true
		}
	}
	delete(others, owner)
	if owner == "" {
		return // no owner yet: nothing to keep from them
	}
	allDone, anyLib := true, false
	defer func() {
		m.privacy.mu.Lock()
		defer m.privacy.mu.Unlock()
		m.privacy.owner, m.privacy.none = owner, !anyLib
		if allDone {
			m.privacy.left = others
		}
	}()
	for _, t := range m.targets {
		if t.Type != "immich" || t.MediaPath == "" {
			continue
		}
		// A photo library configured but not set up yet is not "none": its
		// library is made over the whole pictures folder and scanned at
		// once, so until it is told what to leave out, nothing is known to
		// be private (the thirteenth security pass).
		anyLib = true
		creds, ok := m.store.Backend(t.ID)
		if !ok || creds.LibraryID == "" {
			allDone = false
			continue
		}
		var want []string
		for f := range others {
			want = append(want, path.Join(t.MediaPath, globEscape(f))+"/**")
		}
		slices.Sort(want)
		changed, err := setExclusions(ctx, creds.BaseURL, creds.Token, creds.LibraryID, t.MediaPath, want)
		if err != nil {
			m.log.Warn("could not keep others' photos out of the owner's library", "backend", t.ID, "err", err)
			allDone = false
			continue
		}
		if changed {
			m.log.Info("the owner's photo library leaves out others' own photos", "backend", t.ID, "folders", len(want))
		}
	}
}

// setExclusions makes the library's EmberStorm-written exclusion patterns
// exactly want, keeping any others, and asks for a scan when they changed (a
// scan is what takes left-out photos away and brings let-in ones back).
func setExclusions(ctx context.Context, baseURL, key, libraryID, mediaPath string, want []string) (bool, error) {
	c, err := httpx.New(baseURL, backendTimeout)
	if err != nil {
		return false, err
	}
	authed := map[string]string{"x-api-key": key}
	var lib struct {
		ExclusionPatterns []string `json:"exclusionPatterns"`
	}
	resp, err := c.Do(ctx, httpx.Request{Path: "/api/libraries/" + url.PathEscape(libraryID), Headers: authed})
	if err != nil {
		return false, err
	}
	if err := resp.Err(); err != nil {
		return false, err
	}
	if err := resp.JSON(&lib); err != nil {
		return false, err
	}
	ours := path.Join(mediaPath, "Personal") + "/"
	var keep, current []string
	for _, p := range lib.ExclusionPatterns {
		if strings.HasPrefix(p, ours) {
			current = append(current, p)
		} else {
			keep = append(keep, p)
		}
	}
	slices.Sort(current)
	if slices.Equal(current, want) {
		return false, nil
	}
	patterns := append(keep, want...)
	if patterns == nil {
		patterns = []string{}
	}
	resp, err = c.Do(ctx, httpx.Request{
		Method:  http.MethodPut,
		Path:    "/api/libraries/" + url.PathEscape(libraryID),
		Headers: authed,
		Body:    map[string]any{"exclusionPatterns": patterns},
	})
	if err != nil {
		return false, err
	}
	if err := resp.Err(); err != nil {
		return false, fmt.Errorf("update library: %w", err)
	}
	if resp, err := c.Do(ctx, httpx.Request{
		Method: http.MethodPost, Path: "/api/libraries/" + url.PathEscape(libraryID) + "/scan", Headers: authed,
	}); err == nil {
		_ = resp.Err()
	}
	return true, nil
}

// globEscape keeps a folder's name from being read as a pattern: a person
// called "[Mom]" must leave out exactly that folder.
func globEscape(s string) string {
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune(`*?[]{}()!\+@`, r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

// photoPrivacy is what the last SyncPhotoPrivacy found and did.
type photoPrivacy struct {
	mu    sync.Mutex
	owner string          // the owner's own folder
	left  map[string]bool // folders every photo library leaves out
	none  bool            // no photo library set up yet: nothing to leave out of
	// syncing makes the asks of PhotoFolderPrivate wait on one sync.
	syncing sync.Mutex
}

// PhotoFolderPrivate is nil once the owner's photo library is known to
// leave out folder (relative to pictures/), or folder is the owner's own -
// else it brings the library up to date, and refuses if that fails. Asked
// before anything is put in somebody's own folder, so a photo library that
// could not be told (down, or refusing) holds a member's photos back rather
// than showing them in the owner's app until the next try (the twelfth
// security pass).
func (m *Manager) PhotoFolderPrivate(ctx context.Context, folder string) error {
	if m.privateKnown(folder) {
		return nil
	}
	m.privacy.syncing.Lock()
	defer m.privacy.syncing.Unlock()
	if m.privateKnown(folder) {
		return nil
	}
	m.SyncPhotoPrivacy(ctx)
	if m.privateKnown(folder) {
		return nil
	}
	return errors.New("the photo library is not ready for new photos yet; try again in a few minutes")
}

func (m *Manager) privateKnown(folder string) bool {
	m.privacy.mu.Lock()
	defer m.privacy.mu.Unlock()
	if m.privacy.owner == "" {
		// Not synced since start, or nobody owns the server yet: until a
		// sync, only the case with no owner at all is answered here.
		return len(m.store.Users()) == 0 || m.PhotoFolder == nil
	}
	return m.privacy.none || strings.EqualFold(folder, m.privacy.owner) || m.privacy.left[folder]
}
