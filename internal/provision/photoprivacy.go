package provision

import (
	"context"
	"fmt"
	"net/http"
	"net/url"
	"path"
	"slices"
	"strings"

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
	for _, t := range m.targets {
		if t.Type != "immich" || t.MediaPath == "" {
			continue
		}
		creds, ok := m.store.Backend(t.ID)
		if !ok || creds.LibraryID == "" {
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
