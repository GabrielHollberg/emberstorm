package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/GabrielHollberg/soundstorm/internal/library"
	"github.com/GabrielHollberg/soundstorm/internal/media"
	"github.com/GabrielHollberg/soundstorm/internal/photoimport"
	"github.com/GabrielHollberg/soundstorm/internal/source"
	"github.com/GabrielHollberg/soundstorm/internal/state"
)

// Sending photos to someone (the owner's design, 2026-10-04): anybody picks
// photos and videos of their own and sends them to another person in the
// house, who sees "Mom sent you 12 photos" in Photos and adds them to their
// own photos, or not. What is sent waits in a hidden holding folder
// (library/.photo-inbox, which no backend reads, so nothing shows in their
// timeline before they say yes) as hard links to the sender's files - no
// second copy on the disk - or a copy where a link is not possible. Accepted,
// each is filed into the recipient's own folder by when it was taken, like
// anything else they add, so their folder holds a complete file of every
// photo they accepted (one they could copy away, the owner's point), which
// stays theirs if the sender deletes theirs. The sender's dates travel with
// the photos (their date file beside each), Live Photos keep their moving
// part, and what the recipient already has is skipped.

const (
	maxSendItems   = 500
	maxPendingTo   = 100 // waiting sends one person may have
	sendKeep       = 30 * 24 * time.Hour
	photoInboxDir  = ".photo-inbox" // in the library root: no backend mounts it
	sendsStateFile = "photo-sends.json"
)

type photoSend struct {
	ID       string     `json:"id"`
	From     string     `json:"from"`
	FromName string     `json:"fromName"`
	To       string     `json:"to"`
	At       time.Time  `json:"at"`
	Items    []sendItem `json:"items"`
}

type sendItem struct {
	Name   string   `json:"name"`             // the file's name, as it is filed under
	Held   string   `json:"held"`             // its name in the send's holding folder
	Source string   `json:"source"`           // the sender's photo source,
	Asset  string   `json:"asset"`            // and photo, for its preview
	Video  bool     `json:"video,omitempty"`  // a clip
	Extras []string `json:"extras,omitempty"` // held files that go with it: a Live Photo's moving part
	// When the sender's library says it was taken: for a photo with no date
	// inside it, so it lands in the same month for both, not Undated.
	Taken string `json:"taken,omitempty"`
}

// liveFiler is a photo source that knows a Live Photo's moving part's file.
type liveFiler interface {
	LiveFile(ctx context.Context, id string) (string, error)
}

// photoSends is the record of what waits, kept in the state folder (not
// state.json, which every sign-in rewrites).
type photoSends struct {
	mu    sync.Mutex
	file  string // "" with no state folder: kept in memory only
	sends []photoSend
	read  bool
}

func (s *Server) loadSendsLocked() {
	p := &s.photoSendsRec
	if p.read {
		return
	}
	p.read = true
	if data, err := os.ReadFile(p.file); p.file != "" && err == nil {
		_ = json.Unmarshal(data, &p.sends)
	}
	// Anything older than a month was neither taken nor turned down: let go.
	kept := p.sends[:0]
	for _, sd := range p.sends {
		if time.Since(sd.At) < sendKeep {
			kept = append(kept, sd)
		} else {
			_ = os.RemoveAll(s.sendDir(sd.ID))
		}
	}
	p.sends = kept
}

func (s *Server) saveSendsLocked() error {
	file := s.photoSendsRec.file
	if file == "" {
		return nil
	}
	data, err := json.Marshal(s.photoSendsRec.sends)
	if err != nil {
		return err
	}
	tmp := file + ".tmp"
	if err := os.WriteFile(tmp, data, 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, file)
}

func (s *Server) sendDir(id string) string {
	return filepath.Join(s.library.Root(), photoInboxDir, id)
}

// takeSend removes a waiting send meant for userID and hands it back.
func (s *Server) takeSend(id, userID string) (photoSend, bool) {
	p := &s.photoSendsRec
	p.mu.Lock()
	defer p.mu.Unlock()
	s.loadSendsLocked()
	for i, sd := range p.sends {
		if sd.ID == id && sd.To == userID {
			p.sends = append(p.sends[:i], p.sends[i+1:]...)
			_ = s.saveSendsLocked()
			return sd, true
		}
	}
	return photoSend{}, false
}

// forgetSendsTo lets go of everything waiting for somebody removed.
func (s *Server) forgetSendsTo(userID string) {
	p := &s.photoSendsRec
	p.mu.Lock()
	defer p.mu.Unlock()
	s.loadSendsLocked()
	kept := p.sends[:0]
	for _, sd := range p.sends {
		if sd.To == userID {
			_ = os.RemoveAll(s.sendDir(sd.ID))
			continue
		}
		kept = append(kept, sd)
	}
	p.sends = kept
	_ = s.saveSendsLocked()
}

// mayHavePhotos is whether an account has the picture shelf.
func mayHavePhotos(u state.User) bool {
	if u.IsOwner() || u.Libraries == nil {
		return true
	}
	for _, k := range u.Libraries {
		if k == string(media.KindPicture) {
			return true
		}
	}
	return false
}

// holdFile puts a file in the holding folder: a hard link (no second copy),
// else a copy.
func holdFile(from, to string) error {
	st, err := os.Stat(from)
	if err != nil || !st.Mode().IsRegular() {
		return errors.New("not a file")
	}
	if os.Link(from, to) == nil {
		return nil
	}
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o666)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		os.Remove(to)
		return err
	}
	return out.Close()
}

// GET /api/photos/send-to: who photos can be sent to - everybody else in the
// house with Photos.
func (s *Server) handleSendTo(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	people := []map[string]any{}
	for _, o := range s.store.Users() {
		if o.ID == u.ID || !mayHavePhotos(o) {
			continue
		}
		people = append(people, s.withPicture(map[string]any{"id": o.ID, "name": o.Name}, o.ID))
	}
	writeJSON(w, http.StatusOK, map[string]any{"people": people})
}

// POST /api/photos/send {"to": user id, "items": [{"sourceId","id"}...]}:
// sends these photos and videos, the sender's own, to someone.
func (s *Server) handleSendPhotos(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	var body struct {
		To    string `json:"to"`
		Items []struct {
			SourceID string `json:"sourceId"`
			ID       string `json:"id"`
		} `json:"items"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)).Decode(&body); err != nil || len(body.Items) == 0 || len(body.Items) > maxSendItems {
		writeError(w, http.StatusBadRequest, fmt.Sprintf("expected someone to send to and 1 to %d photos", maxSendItems))
		return
	}
	to, found := s.store.User(body.To)
	if !found || to.ID == u.ID || !mayHavePhotos(to) {
		writeError(w, http.StatusBadRequest, "photos can only be sent to someone else here who has Photos")
		return
	}
	if !mayHavePhotos(u) {
		writeError(w, http.StatusForbidden, "you do not have Photos")
		return
	}
	p := &s.photoSendsRec
	p.mu.Lock()
	s.loadSendsLocked()
	waiting := 0
	for _, sd := range p.sends {
		if sd.To == to.ID {
			waiting++
		}
	}
	p.mu.Unlock()
	if waiting >= maxPendingTo {
		writeError(w, http.StatusTooManyRequests, to.Name+" has too many photos waiting to be looked at; try again once they have")
		return
	}

	sd := photoSend{ID: randomHex(12), From: u.ID, FromName: u.Name, To: to.ID, At: time.Now().UTC()}
	dir := s.sendDir(sd.ID)
	if err := os.MkdirAll(dir, 0o777); err != nil {
		writeError(w, http.StatusInternalServerError, "could not get them ready to send")
		return
	}
	type ref = struct{ SourceID, ID string }
	refs := make([]ref, len(body.Items))
	for i, it := range body.Items {
		refs[i] = ref{it.SourceID, it.ID}
	}
	var skipped int
	sd.Items, skipped = s.holdPhotos(r.Context(), dir, refs, false)
	if len(sd.Items) == 0 {
		_ = os.RemoveAll(dir)
		writeError(w, http.StatusBadRequest, "none of those could be sent - only your own photos and videos can")
		return
	}
	p.mu.Lock()
	s.loadSendsLocked()
	p.sends = append(p.sends, sd)
	err := s.saveSendsLocked()
	p.mu.Unlock()
	if err != nil {
		_ = os.RemoveAll(dir)
		writeError(w, http.StatusInternalServerError, "could not send them")
		return
	}
	s.log.Info("photos sent", "from", u.Name, "to", to.Name, "count", len(sd.Items))
	writeJSON(w, http.StatusOK, map[string]any{"sent": len(sd.Items), "skipped": skipped, "to": to.Name})
}

// GET /api/photos/inbox: what others have sent this person, waiting.
func (s *Server) handlePhotoInbox(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	p := &s.photoSendsRec
	p.mu.Lock()
	s.loadSendsLocked()
	out := []map[string]any{}
	for _, sd := range p.sends {
		if sd.To != u.ID {
			continue
		}
		videos := 0
		previews := []map[string]any{}
		for n, it := range sd.Items {
			if it.Video {
				videos++
			}
			if len(previews) < 12 {
				previews = append(previews, map[string]any{
					"thumb": fmt.Sprintf("/api/photos/inbox/%s/%d/thumb", sd.ID, n),
					"video": it.Video,
				})
			}
		}
		out = append(out, map[string]any{
			"id": sd.ID, "from": sd.FromName, "at": sd.At, "count": len(sd.Items),
			"videos": videos, "previews": previews,
		})
	}
	p.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"sends": out, "shares": s.sharesFor(u.ID)})
}

// GET /api/photos/inbox/{id}/{n}/thumb: a waiting photo's thumbnail, from
// the sender's photo library (SoundStorm cannot draw a HEIC itself), for
// the person it was sent to only.
func (s *Server) handlePhotoInboxThumb(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	n, err := strconv.Atoi(r.PathValue("n"))
	if err != nil {
		writeError(w, http.StatusNotFound, "no such photo")
		return
	}
	p := &s.photoSendsRec
	p.mu.Lock()
	s.loadSendsLocked()
	var item *sendItem
	var from string
	for _, sd := range p.sends {
		if sd.ID == r.PathValue("id") && sd.To == u.ID && n >= 0 && n < len(sd.Items) {
			it := sd.Items[n]
			item, from = &it, sd.From
		}
	}
	p.mu.Unlock()
	if item == nil {
		writeError(w, http.StatusNotFound, "no such photo")
		return
	}
	// As the sender: theirs to show, and only this one photo.
	s.proxy.ServeArt(w, r.WithContext(source.WithUserID(r.Context(), from)), item.Source, item.Asset)
}

// POST /api/photos/inbox/{id}/accept: into this person's own photos, each
// filed by when it was taken.
func (s *Server) handlePhotoInboxAccept(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	sd, found := s.takeSend(r.PathValue("id"), u.ID)
	if !found {
		writeError(w, http.StatusNotFound, "those photos are no longer waiting")
		return
	}
	dir := s.sendDir(sd.ID)
	// Let go of once done - but not if it is put back to wait.
	keep := false
	defer func() {
		if !keep {
			_ = os.RemoveAll(dir)
		}
	}()
	if !u.IsOwner() {
		var total int64
		for _, it := range sd.Items {
			if st, err := os.Stat(filepath.Join(dir, it.Held)); err == nil {
				total += st.Size()
			}
		}
		if err := s.photoRoom(u, total); err != nil {
			keep = true
			s.restoreSend(sd)
			writeError(w, http.StatusInsufficientStorage, err.Error())
			return
		}
	}
	if _, err := s.library.EnsurePersonalFolder(u.Name); err != nil {
		keep = true
		s.restoreSend(sd)
		writeError(w, http.StatusInternalServerError, desensitizeFSError(err))
		return
	}
	added, already := s.fileHeld(u, dir, sd.Items)
	if added > 0 {
		s.scheduleRescan(media.KindPicture)
	}
	s.log.Info("sent photos added", "to", u.Name, "from", sd.FromName, "added", added, "already", already)
	writeJSON(w, http.StatusOK, map[string]any{"added": added, "already": already, "from": sd.FromName})
}

// POST /api/photos/inbox/{id}/decline: not wanted; let go of them.
func (s *Server) handlePhotoInboxDecline(w http.ResponseWriter, r *http.Request) {
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	sd, found := s.takeSend(r.PathValue("id"), u.ID)
	if !found {
		writeError(w, http.StatusNotFound, "those photos are no longer waiting")
		return
	}
	_ = os.RemoveAll(s.sendDir(sd.ID))
	writeJSON(w, http.StatusOK, map[string]any{"declined": true})
}

// restoreSend puts back a send that could not be taken after all.
func (s *Server) restoreSend(sd photoSend) {
	p := &s.photoSendsRec
	p.mu.Lock()
	defer p.mu.Unlock()
	s.loadSendsLocked()
	p.sends = append(p.sends, sd)
	_ = s.saveSendsLocked()
}

// holdPhotos puts these photos - the asker's own, or ones shared with them -
// with their date files and a Live Photo's moving part into a holding
// folder, linked where the drive allows. What cannot be found is skipped.
// visibleLister finds the file of any photo the asker can see, their own or
// one shared with them (immich.VisibleItemFiles).
type visibleLister interface {
	VisibleItemFiles(ctx context.Context, id string) ([]string, error)
}

func (s *Server) holdPhotos(ctx context.Context, dir string, refs []struct{ SourceID, ID string }, shared bool) ([]sendItem, int) {
	var items []sendItem
	pictures := s.library.PathFor(media.KindPicture)
	skipped := 0
	for i, it := range refs {
		src, ok := s.reg.ByID(ctx, it.SourceID)
		if !ok || src.Kind() != media.KindPicture {
			skipped++
			continue
		}
		lister, ok := src.(source.FileLister)
		if !ok {
			skipped++
			continue
		}
		// Only the sender's own photos: their photo account answers for
		// nothing else.
		var rels []string
		var err error
		if v, ok := src.(visibleLister); ok && shared {
			rels, err = v.VisibleItemFiles(ctx, it.ID)
		} else {
			rels, err = lister.ItemFiles(ctx, it.ID)
		}
		if err != nil || len(rels) == 0 {
			skipped++
			continue
		}
		abs, err := inside(pictures, rels[0])
		if err != nil {
			skipped++
			continue
		}
		name := path.Base(rels[0])
		held := fmt.Sprintf("%03d-%s", i, name)
		if err := holdFile(abs, filepath.Join(dir, held)); err != nil {
			skipped++
			continue
		}
		item := sendItem{Name: name, Held: held, Source: it.SourceID, Asset: it.ID, Video: !library.IsStillImage(name)}
		if g, ok := src.(source.ItemGetter); ok {
			if got, ok := g.ItemByID(ctx, it.ID); ok {
				item.Taken = got.Extra["taken"]
			}
		}
		// Its date file travels with it: where the sender's date came from.
		_ = holdFile(abs+".xmp", filepath.Join(dir, held+".xmp"))
		// A Live Photo's moving part goes with its still.
		if lf, ok := src.(liveFiler); ok {
			if rel, err := lf.LiveFile(ctx, it.ID); err == nil && rel != "" {
				if labs, err := inside(pictures, rel); err == nil {
					extra := fmt.Sprintf("%03d-live-%s", i, path.Base(rel))
					if holdFile(labs, filepath.Join(dir, extra)) == nil {
						item.Extras = append(item.Extras, extra)
					}
				}
			}
		}
		items = append(items, item)
	}
	return items, skipped
}

// fileHeld files held photos into the person's own folder by when each was
// taken - the date inside it, else the date file that came with it, else
// the date its library showed, else its name - and says how many were
// added and how many they had already.
func (s *Server) fileHeld(u state.User, dir string, items []sendItem) (int, int) {
	added, already := 0, 0
	root := s.library.Root()
	for _, it := range items {
		held := filepath.Join(dir, it.Held)
		// The sender's date, where it came from beside the photo.
		var known photoimport.Meta
		var knownSrc photoimport.DateSource
		if data, err := os.ReadFile(held + ".xmp"); err == nil {
			known, knownSrc = photoimport.ReadSidecar(data)
		}
		if known.Taken.IsZero() && it.Taken != "" {
			if t, err := time.Parse("2006-01-02T15:04:05", it.Taken); err == nil {
				known.Taken, knownSrc = t, photoimport.SourceFile
			}
		}
		pl, err := s.datedPhotoKnown(u, held, it.Name, 0, known, knownSrc)
		if err != nil {
			if errors.Is(err, library.ErrAlreadyThere) {
				already++
			}
			continue
		}
		dest := filepath.Join(root, "pictures", filepath.FromSlash(pl.rel))
		if err := os.MkdirAll(filepath.Dir(dest), 0o777); err != nil {
			continue
		}
		if err := library.MoveNoClobber(held, dest); err != nil {
			if errors.Is(err, library.ErrAlreadyThere) {
				already++
			}
			continue
		}
		// The moving part of a Live Photo, beside its still.
		for _, x := range it.Extras {
			name := strings.TrimPrefix(x, x[:strings.Index(x, "-live-")+len("-live-")])
			_ = library.MoveNoClobber(filepath.Join(dir, x), filepath.Join(filepath.Dir(dest), name))
		}
		s.photoSaved(u, "pictures/"+pl.rel, pl)
		added++
	}
	return added, already
}
