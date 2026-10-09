package httpapi

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/GabrielHollberg/soundstorm/internal/media"
	"github.com/GabrielHollberg/soundstorm/internal/source"
	"github.com/GabrielHollberg/soundstorm/internal/state"
)

// Sharing an album (the owner's design, 2026-10-04): the photos stay their
// owner's - whoever it is shared with sees them, as long as they are in it -
// and nobody gets an album pushed on them: sharing sends an invitation, a
// card at the top of their Photos ("Gabriel shared the album Beach day with
// you"), and only Add to my albums puts them in it. "Can view" or "Can add
// photos" (theirs then show to everyone in it, staying in their own
// folder). Keeping something for good is Save to my photos: real copies in
// their own folder, filed as Send to's are. The photo library does the
// sharing itself (source.PhotoAlbumSharing: Immich's album users).

const (
	sharesStateFile = "photo-shares.json"
	shareKeep       = 30 * 24 * time.Hour
	maxSharesTo     = 50
	sharePreviews   = 8
	maxSaveItems    = 500
)

type albumShare struct {
	ID        string    `json:"id"`
	From      string    `json:"from"`
	FromName  string    `json:"fromName"`
	To        string    `json:"to"`
	Source    string    `json:"source"`
	Album     string    `json:"album"`
	AlbumName string    `json:"albumName"`
	Count     int       `json:"count"`
	CanAdd    bool      `json:"canAdd,omitempty"`
	At        time.Time `json:"at"`
	Previews  []string  `json:"previews,omitempty"`
}

type photoShares struct {
	mu     sync.Mutex
	file   string
	shares []albumShare
	read   bool
}

func (s *Server) loadSharesLocked() {
	p := &s.photoSharesRec
	if p.read {
		return
	}
	p.read = true
	if data, err := os.ReadFile(p.file); p.file != "" && err == nil {
		_ = json.Unmarshal(data, &p.shares)
	}
	kept := p.shares[:0]
	for _, sh := range p.shares {
		if time.Since(sh.At) < shareKeep {
			kept = append(kept, sh)
		}
	}
	p.shares = kept
}

func (s *Server) saveSharesLocked() error {
	p := &s.photoSharesRec
	if p.file == "" {
		return nil
	}
	data, err := json.Marshal(p.shares)
	if err != nil {
		return err
	}
	tmp := p.file + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, p.file)
}

// forgetSharesOf lets go of invitations from or to somebody removed.
func (s *Server) forgetSharesOf(userID string) {
	p := &s.photoSharesRec
	p.mu.Lock()
	defer p.mu.Unlock()
	s.loadSharesLocked()
	kept := p.shares[:0]
	for _, sh := range p.shares {
		if sh.To != userID && sh.From != userID {
			kept = append(kept, sh)
		}
	}
	p.shares = kept
	_ = s.saveSharesLocked()
}

func (s *Server) albumSharing(ctx context.Context) (source.PhotoAlbums, source.PhotoAlbumSharing, string, bool) {
	a, src, ok := s.photoAlbums(ctx)
	if !ok {
		return nil, nil, "", false
	}
	sh, ok := a.(source.PhotoAlbumSharing)
	return a, sh, src, ok
}

// photoUIDs maps people to their photo account's own id: a member's is
// recorded with their account; the owner's (the administrator's) is asked
// once.
func (s *Server) photoUIDs(ctx context.Context, sh source.PhotoAlbumSharing, src string) map[string]state.User {
	out := map[string]state.User{}
	for _, u := range s.store.Users() {
		if u.IsOwner() {
			s.ownerUIDMu.Lock()
			uid := s.ownerUID
			s.ownerUIDMu.Unlock()
			if uid == "" {
				if got, err := sh.PhotoUserID(source.WithUserID(ctx, u.ID)); err == nil {
					uid = got
					s.ownerUIDMu.Lock()
					s.ownerUID = got
					s.ownerUIDMu.Unlock()
				}
			}
			if uid != "" {
				out[uid] = u
			}
			continue
		}
		if id, ok := s.store.Identity(u.ID, src); ok && id.RemoteID != "" {
			out[id.RemoteID] = u
		}
	}
	return out
}

type sharePerson struct {
	ID      string `json:"id"`
	Name    string `json:"name"`
	CanAdd  bool   `json:"canAdd"`
	Waiting bool   `json:"waiting,omitempty"`
}

// albumsOut says, of each album, whose it is, who it is shared with and
// who has not answered yet, and whether the asker may add to it.
func (s *Server) albumsOut(ctx context.Context, u state.User, albums []source.PhotoAlbum, src string) []albumOut {
	out := make([]albumOut, len(albums))
	_, sh, _, sharing := s.albumSharing(ctx)
	var people map[string]state.User
	var me string
	if sharing {
		people = s.photoUIDs(ctx, sh, src)
		for uid, p := range people {
			if p.ID == u.ID {
				me = uid
			}
		}
	}
	p := &s.photoSharesRec
	p.mu.Lock()
	s.loadSharesLocked()
	waiting := append([]albumShare(nil), p.shares...)
	p.mu.Unlock()
	for i, al := range albums {
		o := albumOut{PhotoAlbum: al, SourceID: src, Owned: true, CanAdd: true, SharedWith: []sharePerson{}}
		if sharing && al.Owner != "" && al.Owner != me {
			o.Owned = false
			o.OwnerName = people[al.Owner].Name
			o.CanAdd = false
		}
		for _, m := range al.Members {
			who, known := people[m.UserID]
			if m.UserID == me && m.Role == "editor" {
				o.CanAdd = true
			}
			if known {
				o.SharedWith = append(o.SharedWith, sharePerson{ID: who.ID, Name: who.Name, CanAdd: m.Role == "editor"})
			}
		}
		if o.Owned {
			for _, w := range waiting {
				if w.Album == al.ID && w.From == u.ID {
					if to, ok := s.store.User(w.To); ok {
						o.SharedWith = append(o.SharedWith, sharePerson{ID: to.ID, Name: to.Name, CanAdd: w.CanAdd, Waiting: true})
					}
				}
			}
		}
		out[i] = o
	}
	return out
}

// ownedAlbum is the asker's own album by id.
func (s *Server) ownedAlbum(w http.ResponseWriter, r *http.Request, u state.User) (source.PhotoAlbums, source.PhotoAlbumSharing, string, albumOut, bool) {
	ctx := r.Context()
	a, sh, src, ok := s.albumSharing(ctx)
	if !ok {
		writeError(w, http.StatusNotFound, "albums cannot be shared here")
		return nil, nil, "", albumOut{}, false
	}
	albums, err := a.Albums(ctx)
	if err != nil {
		s.photosError(w, err)
		return nil, nil, "", albumOut{}, false
	}
	for _, o := range s.albumsOut(ctx, u, albums, src) {
		if o.ID == r.PathValue("id") {
			if !o.Owned {
				writeError(w, http.StatusForbidden, "only "+o.OwnerName+" can share this album")
				return nil, nil, "", albumOut{}, false
			}
			return a, sh, src, o, true
		}
	}
	writeError(w, http.StatusNotFound, "no such album")
	return nil, nil, "", albumOut{}, false
}

// POST /api/photos/albums/{id}/share {to, canAdd}: an invitation to the
// asker's album; somebody already in it has what they may do changed.
func (s *Server) handleShareAlbum(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	var body struct {
		To     string `json:"to"`
		CanAdd bool   `json:"canAdd"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "expected someone to share it with")
		return
	}
	to, found := s.store.User(body.To)
	if !found || to.ID == u.ID || !mayHavePhotos(to) {
		writeError(w, http.StatusBadRequest, "an album can only be shared with someone else here who has Photos")
		return
	}
	a, sh, src, al, ok := s.ownedAlbum(w, r, u)
	if !ok {
		return
	}
	for _, m := range al.SharedWith {
		if m.ID == to.ID && !m.Waiting {
			uid := ""
			if id, ok := s.store.Identity(to.ID, src); ok {
				uid = id.RemoteID
			}
			if to.IsOwner() {
				s.ownerUIDMu.Lock()
				uid = s.ownerUID
				s.ownerUIDMu.Unlock()
			}
			if err := sh.ShareAlbum(r.Context(), al.ID, uid, body.CanAdd); err != nil {
				s.photosError(w, err)
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"changed": true, "to": to.Name})
			return
		}
	}
	var previews []string
	if items, err := a.AlbumPhotos(r.Context(), al.ID, sharePreviews); err == nil {
		for _, it := range items {
			previews = append(previews, it.ID)
		}
	}
	p := &s.photoSharesRec
	p.mu.Lock()
	defer p.mu.Unlock()
	s.loadSharesLocked()
	waiting := 0
	for i, w0 := range p.shares {
		if w0.To == to.ID {
			waiting++
		}
		if w0.Album == al.ID && w0.To == to.ID {
			p.shares[i].CanAdd = body.CanAdd
			_ = s.saveSharesLocked()
			writeJSON(w, http.StatusOK, map[string]any{"invited": true, "to": to.Name})
			return
		}
	}
	if waiting >= maxSharesTo {
		writeError(w, http.StatusTooManyRequests, to.Name+" has too many albums waiting to be looked at")
		return
	}
	p.shares = append(p.shares, albumShare{ID: randomHex(12), From: u.ID, FromName: u.Name, To: to.ID, Source: src,
		Album: al.ID, AlbumName: al.Name, Count: al.Count, CanAdd: body.CanAdd, At: time.Now().UTC(), Previews: previews})
	if err := s.saveSharesLocked(); err != nil {
		writeError(w, http.StatusInternalServerError, "could not share it")
		return
	}
	s.log.Info("album shared", "from", u.Name, "to", to.Name)
	writeJSON(w, http.StatusOK, map[string]any{"invited": true, "to": to.Name})
}

// DELETE /api/photos/albums/{id}/share/{user}: stops sharing with someone,
// or takes back an invitation they have not answered.
func (s *Server) handleUnshareAlbum(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	_, sh, src, al, ok := s.ownedAlbum(w, r, u)
	if !ok {
		return
	}
	who := r.PathValue("user")
	p := &s.photoSharesRec
	p.mu.Lock()
	s.loadSharesLocked()
	took := false
	kept := p.shares[:0]
	for _, w0 := range p.shares {
		if w0.Album == al.ID && w0.To == who && w0.From == u.ID {
			took = true
			continue
		}
		kept = append(kept, w0)
	}
	p.shares = kept
	_ = s.saveSharesLocked()
	p.mu.Unlock()
	if took {
		writeJSON(w, http.StatusOK, map[string]any{"stopped": true})
		return
	}
	for uid, person := range s.photoUIDs(r.Context(), sh, src) {
		if person.ID == who {
			if err := sh.UnshareAlbum(r.Context(), al.ID, uid); err != nil {
				s.photosError(w, err)
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"stopped": true})
			return
		}
	}
	writeError(w, http.StatusNotFound, "it is not shared with them")
}

// POST /api/photos/albums/{id}/leave: off an album shared with the asker.
func (s *Server) handleLeaveAlbum(w http.ResponseWriter, r *http.Request) {
	if _, ok := s.requireUser(w, r); !ok {
		return
	}
	_, sh, _, ok := s.albumSharing(r.Context())
	if !ok {
		writeError(w, http.StatusNotFound, "no shared albums here")
		return
	}
	if err := sh.UnshareAlbum(r.Context(), r.PathValue("id"), "me"); err != nil {
		s.photosError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"left": true})
}

// sharesFor is the invitations waiting for somebody, as the inbox shows them.
func (s *Server) sharesFor(userID string) []map[string]any {
	p := &s.photoSharesRec
	p.mu.Lock()
	defer p.mu.Unlock()
	s.loadSharesLocked()
	out := []map[string]any{}
	for _, sh := range p.shares {
		if sh.To != userID {
			continue
		}
		previews := []string{}
		for n := range sh.Previews {
			previews = append(previews, fmt.Sprintf("/api/photos/shares/%s/%d/thumb", sh.ID, n))
		}
		out = append(out, map[string]any{"id": sh.ID, "from": sh.FromName, "album": sh.AlbumName, "count": sh.Count,
			"canAdd": sh.CanAdd, "at": sh.At, "previews": previews})
	}
	return out
}

func (s *Server) takeShare(id, userID string) (albumShare, bool) {
	p := &s.photoSharesRec
	p.mu.Lock()
	defer p.mu.Unlock()
	s.loadSharesLocked()
	for i, sh := range p.shares {
		if sh.ID == id && sh.To == userID {
			p.shares = append(p.shares[:i], p.shares[i+1:]...)
			_ = s.saveSharesLocked()
			return sh, true
		}
	}
	return albumShare{}, false
}

// GET /api/photos/shares/{id}/{n}/thumb: a preview of an album waiting to be
// added, from its owner's library, for the person invited only.
func (s *Server) handleShareThumb(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	n, err := strconv.Atoi(r.PathValue("n"))
	p := &s.photoSharesRec
	p.mu.Lock()
	s.loadSharesLocked()
	var asset, from, src string
	for _, sh := range p.shares {
		if err == nil && sh.ID == r.PathValue("id") && sh.To == u.ID && n >= 0 && n < len(sh.Previews) {
			asset, from, src = sh.Previews[n], sh.From, sh.Source
		}
	}
	p.mu.Unlock()
	if asset == "" {
		writeError(w, http.StatusNotFound, "no such photo")
		return
	}
	s.proxy.ServeArt(w, r.WithContext(source.WithUserID(r.Context(), from)), src, asset)
}

// POST /api/photos/shares/{id}/accept: into the album.
func (s *Server) handleAcceptShare(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	_, sh, _, ok := s.albumSharing(r.Context())
	if !ok {
		writeError(w, http.StatusNotFound, "no shared albums here")
		return
	}
	inv, found := s.takeShare(r.PathValue("id"), u.ID)
	if !found {
		writeError(w, http.StatusNotFound, "that album is no longer waiting")
		return
	}
	put := func() {
		p := &s.photoSharesRec
		p.mu.Lock()
		defer p.mu.Unlock()
		p.shares = append(p.shares, inv)
		_ = s.saveSharesLocked()
	}
	// The asker's own photo account (made now if this is their first look).
	uid, err := sh.PhotoUserID(r.Context())
	if err != nil {
		put()
		s.photosError(w, err)
		return
	}
	if err := sh.ShareAlbum(source.WithUserID(r.Context(), inv.From), inv.Album, uid, inv.CanAdd); err != nil {
		put()
		s.photosError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"album": inv.Album, "name": inv.AlbumName, "from": inv.FromName})
}

// POST /api/photos/shares/{id}/decline.
func (s *Server) handleDeclineShare(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	if _, found := s.takeShare(r.PathValue("id"), u.ID); !found {
		writeError(w, http.StatusNotFound, "that album is no longer waiting")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"declined": true})
}

// POST /api/photos/save {items}: copies of photos the asker can see (in an
// album shared with them) into their own folder, filed by date.
func (s *Server) handleSavePhotos(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	if !mayHavePhotos(u) {
		writeError(w, http.StatusForbidden, "you do not have Photos")
		return
	}
	var body struct {
		Items []struct {
			SourceID string `json:"sourceId"`
			ID       string `json:"id"`
		} `json:"items"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)).Decode(&body); err != nil || len(body.Items) == 0 || len(body.Items) > maxSaveItems {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("expected 1 to %d photos", maxSaveItems))
		return
	}
	refs := make([]struct{ SourceID, ID string }, len(body.Items))
	for i, it := range body.Items {
		refs[i] = struct{ SourceID, ID string }{it.SourceID, it.ID}
	}
	dir := filepath.Join(s.library.Root(), photoInboxDir, "save-"+randomHex(8))
	if err := os.MkdirAll(dir, 0o777); err != nil {
		writeError(w, http.StatusInternalServerError, "could not get them ready")
		return
	}
	defer os.RemoveAll(dir)
	held, skipped := s.holdPhotos(r.Context(), dir, refs, true)
	if len(held) == 0 {
		writeError(w, http.StatusBadRequest, "none of those could be saved")
		return
	}
	if !u.IsOwner() {
		var total int64
		for _, it := range held {
			if st, err := os.Stat(filepath.Join(dir, it.Held)); err == nil {
				total += st.Size()
			}
		}
		release, err := s.holdPhotoRoom(u, total)
		if err != nil {
			writeError(w, http.StatusInsufficientStorage, err.Error())
			return
		}
		defer release()
	}
	if _, err := s.library.EnsurePersonalFolder(u.Name); err != nil {
		writeError(w, http.StatusInternalServerError, desensitizeFSError(err))
		return
	}
	added, already := s.fileHeld(u, dir, held)
	if added > 0 {
		s.scheduleRescan(media.KindPicture)
	}
	writeJSON(w, http.StatusOK, map[string]any{"added": added, "already": already, "skipped": skipped})
}
