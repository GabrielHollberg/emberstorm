package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"path"
	"time"

	"github.com/GabrielHollberg/soundstorm/internal/auth"
	"github.com/GabrielHollberg/soundstorm/internal/library"
	"github.com/GabrielHollberg/soundstorm/internal/media"
	"github.com/GabrielHollberg/soundstorm/internal/source"
)

// Number the episodes (the owner's asking, 2026-10-09): a show's files with
// their lengths, ordered and numbered (library.SuggestEpisodes), for the
// owner to put right - reorder, renumber, mark a play-all or an extra - and
// apply, which renames them as Jellyfin reads episodes
// (library.ApplyEpisodes). Owner only: every account shares the shelf, and
// files are renamed and play-alls binned.
//
//	GET  /api/tv/numbering?source=&id=   {folder, show, rows}
//	POST /api/tv/numbering               {source, id, rows:[{path, role, season, episode}]}

// showFolder is a show's folder on the TV shelf, from the backend.
func (s *Server) showFolder(ctx context.Context, sourceID, seriesID string) (source.Source, string, error) {
	src, ok := s.reg.ByID(ctx, sourceID)
	if !ok || src.Kind() != media.KindTV {
		return nil, "", errors.New("that is not a TV show here")
	}
	fl, ok := src.(source.FileLister)
	if !ok {
		return nil, "", errors.New("that library cannot say where its files are")
	}
	files, err := fl.ItemFiles(ctx, seriesID)
	if err != nil || len(files) != 1 {
		return nil, "", errors.New("could not find the show's folder")
	}
	folder := files[0]
	if path.Ext(folder) != "" {
		folder = path.Dir(folder) // a show that is one file
	}
	return src, folder, nil
}

func (s *Server) handleNumbering(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 60*time.Second)
	defer cancel()
	q := r.URL.Query()
	src, folder, err := s.showFolder(ctx, q.Get("source"), q.Get("id"))
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	files, err := s.library.ShowFiles(folder)
	if err != nil {
		writeError(w, http.StatusBadRequest, desensitizeFSError(err))
		return
	}
	// Lengths, where the backend knows them: a play-all and an extra are told
	// by them more surely than by size.
	if sb, ok := src.(source.ShowBrowser); ok {
		if eps, err := sb.Episodes(ctx, q.Get("id")); err == nil {
			fl, _ := src.(source.FileLister)
			length := map[string]float64{}
			for i, e := range eps {
				if i >= 400 || fl == nil || e.DurationSeconds <= 0 {
					continue
				}
				if rels, err := fl.ItemFiles(ctx, e.ID); err == nil && len(rels) > 0 {
					length[rels[0]] = float64(e.DurationSeconds)
				}
			}
			for i := range files {
				files[i].Seconds = length[files[i].Rel]
			}
		}
	}
	show := library.ShowName(folder)
	rows := library.SuggestEpisodes(folder, show, files, 0, 0)
	writeJSON(w, http.StatusOK, map[string]any{"folder": folder, "show": show, "rows": rows})
}

func (s *Server) handleApplyNumbering(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Source string               `json:"source"`
		ID     string               `json:"id"`
		Rows   []library.EpisodeRow `json:"rows"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 512<<10)).Decode(&body); err != nil || len(body.Rows) == 0 {
		writeError(w, http.StatusBadRequest, "expected the show and its files")
		return
	}
	if len(body.Rows) > 2000 {
		writeError(w, http.StatusBadRequest, "too many files at once")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	_, folder, err := s.showFolder(ctx, body.Source, body.ID)
	if err != nil {
		writeError(w, http.StatusNotFound, err.Error())
		return
	}
	user, _ := auth.FromContext(r.Context())
	moved, binned, err := s.library.ApplyEpisodes(folder, library.ShowName(folder), body.Rows, user.Name)
	if err != nil {
		status := http.StatusBadRequest
		if errors.Is(err, library.ErrEpisodeTaken) {
			status = http.StatusConflict
		}
		writeError(w, status, desensitizeFSError(err))
		return
	}
	s.log.Info("episodes numbered", "show", folder, "moved", moved, "binned", binned, "by", user.Name)
	s.scheduleRescan(media.KindTV)
	writeJSON(w, http.StatusOK, map[string]int{"moved": moved, "binned": binned})
}
