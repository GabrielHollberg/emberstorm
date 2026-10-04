package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"unicode/utf8"

	"github.com/GabrielHollberg/soundstorm/internal/source"
)

// Photo albums (the owner's design, 2026-10-04): anybody with Photos makes
// albums of their own photos and videos - from a selection's menu or one
// photo's - and finds them under the Photos tab's Albums. They are the photo
// backend's own (source.PhotoAlbums: Immich's, in each person's own photo
// account), so they are as private as the photos; sharing one is next.

const (
	maxAlbumName  = 100
	maxAlbumItems = 500
	albumPhotoMax = 5000
)

func (s *Server) photoAlbums(ctx context.Context) (source.PhotoAlbums, string, bool) {
	b, id, ok := s.photoBrowser(ctx)
	if !ok {
		return nil, "", false
	}
	a, ok := b.(source.PhotoAlbums)
	return a, id, ok
}

type albumOut struct {
	source.PhotoAlbum
	SourceID string `json:"sourceId"`
	// Owned: the asker's own (else OwnerName's, shared with them). CanAdd:
	// they may add photos. SharedWith: who else is in it, and (on their own)
	// who has not answered yet.
	Owned      bool          `json:"owned"`
	OwnerName  string        `json:"ownerName,omitempty"`
	CanAdd     bool          `json:"canAdd"`
	SharedWith []sharePerson `json:"sharedWith"`
}

// albumBody is what the album routes take: a name, and photos as the page
// knows them. Only the photo source's own are kept.
type albumBody struct {
	Name  string `json:"name"`
	Items []struct {
		SourceID string `json:"sourceId"`
		ID       string `json:"id"`
	} `json:"items"`
}

func readAlbumBody(w http.ResponseWriter, r *http.Request, sourceID string) (string, []string, bool) {
	var body albumBody
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256<<10)).Decode(&body); err != nil || len(body.Items) > maxAlbumItems {
		writeError(w, http.StatusBadRequest, "expected an album name and up to 500 photos")
		return "", nil, false
	}
	name := strings.TrimSpace(body.Name)
	if utf8.RuneCountInString(name) > maxAlbumName {
		writeError(w, http.StatusBadRequest, "that name is too long")
		return "", nil, false
	}
	var ids []string
	seen := map[string]bool{}
	for _, it := range body.Items {
		if it.SourceID == sourceID && it.ID != "" && !seen[it.ID] {
			seen[it.ID] = true
			ids = append(ids, it.ID)
		}
	}
	return name, ids, true
}

// GET /api/photos/albums: this person's albums; with ?id= one album's photos.
func (s *Server) handlePhotoAlbums(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), photosDeadline)
	defer cancel()
	a, src, ok := s.photoAlbums(ctx)
	if !ok {
		writeJSON(w, http.StatusOK, map[string]any{"albums": []albumOut{}})
		return
	}
	u, ok := s.requireUser(w, r)
	if !ok {
		return
	}
	albums, err := a.Albums(ctx)
	if err != nil {
		s.photosError(w, err)
		return
	}
	outs := s.albumsOut(ctx, u, albums, src)
	if id := r.URL.Query().Get("id"); id != "" {
		for _, al := range outs {
			if al.ID != id {
				continue
			}
			items, err := a.AlbumPhotos(ctx, id, albumPhotoMax)
			if err != nil {
				s.photosError(w, err)
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"album": al, "items": nonNil(items)})
			return
		}
		writeError(w, http.StatusNotFound, "no such album")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"albums": outs})
}

// POST /api/photos/albums {name, items}: a new album, with these in it.
func (s *Server) handleCreatePhotoAlbum(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), photosDeadline)
	defer cancel()
	a, src, ok := s.photoAlbums(ctx)
	if !ok {
		writeError(w, http.StatusNotFound, "no photos")
		return
	}
	name, ids, ok := readAlbumBody(w, r, src)
	if !ok {
		return
	}
	if name == "" {
		writeError(w, http.StatusBadRequest, "give the album a name")
		return
	}
	al, err := a.CreateAlbum(ctx, name, ids)
	if err != nil {
		s.photosError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"album": albumOut{PhotoAlbum: al, SourceID: src, Owned: true, CanAdd: true, SharedWith: []sharePerson{}}, "added": len(ids)})
}

// POST /api/photos/albums/{id}/add and /remove {items}.
func (s *Server) handlePhotoAlbumItems(add bool) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ctx, cancel := context.WithTimeout(r.Context(), photosDeadline)
		defer cancel()
		a, src, ok := s.photoAlbums(ctx)
		if !ok {
			writeError(w, http.StatusNotFound, "no photos")
			return
		}
		_, ids, ok := readAlbumBody(w, r, src)
		if !ok {
			return
		}
		if len(ids) == 0 {
			writeError(w, http.StatusBadRequest, "no photos to change")
			return
		}
		var n int
		var err error
		if add {
			n, err = a.AddToAlbum(ctx, r.PathValue("id"), ids)
		} else {
			n, err = a.RemoveFromAlbum(ctx, r.PathValue("id"), ids)
		}
		if err != nil {
			s.photosError(w, err)
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"changed": n, "asked": len(ids)})
	}
}

// PATCH /api/photos/albums/{id} {name}.
func (s *Server) handleRenamePhotoAlbum(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), photosDeadline)
	defer cancel()
	a, src, ok := s.photoAlbums(ctx)
	if !ok {
		writeError(w, http.StatusNotFound, "no photos")
		return
	}
	name, _, ok := readAlbumBody(w, r, src)
	if !ok {
		return
	}
	if name == "" {
		writeError(w, http.StatusBadRequest, "give the album a name")
		return
	}
	if err := a.RenameAlbum(ctx, r.PathValue("id"), name); err != nil {
		s.photosError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"name": name})
}

// DELETE /api/photos/albums/{id}: the album goes, never its photos.
func (s *Server) handleDeletePhotoAlbum(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), photosDeadline)
	defer cancel()
	a, _, ok := s.photoAlbums(ctx)
	if !ok {
		writeError(w, http.StatusNotFound, "no photos")
		return
	}
	if err := a.DeleteAlbum(ctx, r.PathValue("id")); err != nil {
		s.photosError(w, err)
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"deleted": true})
}
