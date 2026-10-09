package httpapi

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/GabrielHollberg/soundstorm/internal/auth"
	"github.com/GabrielHollberg/soundstorm/internal/source"
)

// "Find the right film" (2026-10-07, the owner's asking): for a film the
// backend did not recognise from its file name, or got wrong - showing a frame
// of the video for its cover. The owner searches by title, picks from a list
// with posters, and the backend learns which film it is (source.FilmMatcher).
// The file is not touched. Owner only, as deleting and moving are: every
// account shares the shelf.
//
// The answers stay on the server (filmMatches), and the page picks one by its
// place in the list: what is applied is what the backend itself found, never
// anything a browser sent.

type filmMatchCache struct {
	mu sync.Mutex
	m  map[string]filmMatchEntry
}

type filmMatchEntry struct {
	at      time.Time
	matches []source.FilmMatch
}

const filmMatchKeep = 15 * time.Minute

func (c *filmMatchCache) put(key string, matches []source.FilmMatch) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.m == nil || len(c.m) > 64 {
		c.m = map[string]filmMatchEntry{}
	}
	c.m[key] = filmMatchEntry{time.Now(), matches}
}

func (c *filmMatchCache) get(key string) []source.FilmMatch {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[key]
	if !ok || time.Since(e.at) > filmMatchKeep {
		return nil
	}
	return e.matches
}

func (s *Server) filmMatcher(w http.ResponseWriter, r *http.Request) (source.FilmMatcher, string, bool) {
	src, ok := s.reg.ByID(r.Context(), r.PathValue("source"))
	m, matches := src.(source.FilmMatcher)
	if !ok || !matches {
		writeError(w, http.StatusNotFound, "that library cannot look films up")
		return nil, "", false
	}
	user, _ := auth.FromContext(r.Context())
	return m, user.ID + "|" + r.PathValue("source") + "|" + r.PathValue("id"), true
}

// GET /api/films/{source}/{id}/matches?q=&year=
func (s *Server) handleFilmMatches(w http.ResponseWriter, r *http.Request) {
	m, key, ok := s.filmMatcher(w, r)
	if !ok {
		return
	}
	q := strings.TrimSpace(r.URL.Query().Get("q"))
	if q == "" || len(q) > 200 {
		writeError(w, http.StatusBadRequest, "type the film's name")
		return
	}
	year := searchYear(r.URL.Query().Get("year"))
	key += "|" + strings.ToLower(q) + "|" + strconv.Itoa(year)
	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()
	found, err := m.FindMatches(ctx, r.PathValue("id"), q, year)
	if err != nil {
		s.log.Warn("film search", "err", err)
		writeError(w, http.StatusBadGateway, "could not look that up just now; try again")
		return
	}
	s.filmMatches.put(key, found)
	type out struct {
		Index    int    `json:"index"`
		Name     string `json:"name"`
		Year     int    `json:"year,omitempty"`
		Overview string `json:"overview,omitempty"`
		Poster   string `json:"poster,omitempty"`
	}
	list := []out{}
	for i, f := range found {
		o := out{Index: i, Name: f.Name, Year: f.Year, Overview: f.Overview}
		if len([]rune(o.Overview)) > 240 {
			o.Overview = string([]rune(o.Overview)[:240]) + "..."
		}
		if posterAllowed(f.Poster) != "" {
			o.Poster = "/api/films/poster?u=" + url.QueryEscape(f.Poster)
		}
		list = append(list, o)
	}
	writeJSON(w, http.StatusOK, map[string]any{"matches": list})
}

// POST /api/films/{source}/{id}/match {"index"}
func (s *Server) handleFilmMatch(w http.ResponseWriter, r *http.Request) {
	m, key, ok := s.filmMatcher(w, r)
	if !ok {
		return
	}
	// Which search it was chosen from: two can be on their way at once (a
	// word typed while the last was answering), and each keeps its own list.
	var body struct {
		Index int    `json:"index"`
		Q     string `json:"q"`
		Year  string `json:"year"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "expected a JSON body with index")
		return
	}
	key += "|" + strings.ToLower(strings.TrimSpace(body.Q)) + "|" + strconv.Itoa(searchYear(body.Year))
	found := s.filmMatches.get(key)
	if body.Index < 0 || body.Index >= len(found) {
		writeError(w, http.StatusConflict, "search again, then choose")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()
	if err := m.ApplyMatch(ctx, r.PathValue("id"), found[body.Index]); err != nil {
		s.log.Warn("film match", "err", err)
		writeError(w, http.StatusBadGateway, "could not change it just now; try again")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"matched": true, "name": found[body.Index].Name})
}

// Choose a poster (the owner's asking, 2026-10-09): the posters the online
// databases have for a film or show the backend has identified - different
// years, countries, styles - and the one chosen becomes its poster, for
// everyone (source.PosterChooser). As with matches, the list stays on the
// server and the page picks by place: only a poster the backend offered is
// ever applied.
type posterListCache struct {
	mu sync.Mutex
	m  map[string]posterListEntry
}

type posterListEntry struct {
	at      time.Time
	posters []source.PosterChoice
}

func (c *posterListCache) put(key string, posters []source.PosterChoice) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.m == nil || len(c.m) > 64 {
		c.m = map[string]posterListEntry{}
	}
	c.m[key] = posterListEntry{time.Now(), posters}
}

func (c *posterListCache) get(key string) []source.PosterChoice {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.m[key]
	if !ok || time.Since(e.at) > filmMatchKeep {
		return nil
	}
	return e.posters
}

func (s *Server) posterChooser(w http.ResponseWriter, r *http.Request) (source.PosterChooser, string, bool) {
	src, ok := s.reg.ByID(r.Context(), r.PathValue("source"))
	pc, can := src.(source.PosterChooser)
	if !ok || !can {
		writeError(w, http.StatusNotFound, "that library has no posters to choose from")
		return nil, "", false
	}
	user, _ := auth.FromContext(r.Context())
	return pc, user.ID + "|" + r.PathValue("source") + "|" + r.PathValue("id"), true
}

// GET /api/films/{source}/{id}/posters
func (s *Server) handlePosterChoices(w http.ResponseWriter, r *http.Request) {
	pc, key, ok := s.posterChooser(w, r)
	if !ok {
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 25*time.Second)
	defer cancel()
	all, err := pc.Posters(ctx, r.PathValue("id"))
	if err != nil {
		s.log.Warn("poster choices", "err", err)
		writeError(w, http.StatusBadGateway, "could not look them up just now; try again")
		return
	}
	// Only posters the page can be shown through the server (posterAllowed).
	var kept []source.PosterChoice
	for _, p := range all {
		if posterAllowed(p.URL) != "" {
			kept = append(kept, p)
			if len(kept) == 60 {
				break
			}
		}
	}
	s.posterChoices.put(key, kept)
	type out struct {
		Index    int    `json:"index"`
		Poster   string `json:"poster"`
		Width    int    `json:"width,omitempty"`
		Height   int    `json:"height,omitempty"`
		Language string `json:"language,omitempty"`
	}
	list := []out{}
	for i, p := range kept {
		list = append(list, out{
			Index: i, Poster: "/api/films/poster?u=" + url.QueryEscape(p.URL),
			Width: p.Width, Height: p.Height, Language: p.Language,
		})
	}
	writeJSON(w, http.StatusOK, map[string]any{"posters": list})
}

// POST /api/films/{source}/{id}/posters {"index"}
func (s *Server) handleChoosePoster(w http.ResponseWriter, r *http.Request) {
	pc, key, ok := s.posterChooser(w, r)
	if !ok {
		return
	}
	var body struct {
		Index int `json:"index"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "expected a JSON body with index")
		return
	}
	found := s.posterChoices.get(key)
	if body.Index < 0 || body.Index >= len(found) {
		writeError(w, http.StatusConflict, "look at the posters again, then choose")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	if err := pc.ChoosePoster(ctx, r.PathValue("id"), found[body.Index]); err != nil {
		s.log.Warn("choose poster", "err", err)
		writeError(w, http.StatusBadGateway, "could not change it just now; try again")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"set": true})
}

// searchYear is a year typed with a film's name, or 0.
func searchYear(s string) int {
	year, _ := strconv.Atoi(s)
	if year < 1880 || year > 2100 {
		return 0
	}
	return year
}

// posterAllowed is the address to fetch a search's poster from, or "" for one
// that is not a film database's picture: the server fetches it, so an address
// it was handed must not lead anywhere else. TheMovieDb's at a card's size.
func posterAllowed(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Scheme != "https" || u.User != nil || u.Port() != "" {
		return ""
	}
	switch u.Hostname() {
	case "image.tmdb.org":
		if !strings.HasPrefix(u.Path, "/t/p/") {
			return ""
		}
		if parts := strings.SplitN(strings.TrimPrefix(u.Path, "/t/p/"), "/", 2); len(parts) == 2 {
			u.Path = "/t/p/w342/" + parts[1]
		}
	case "m.media-amazon.com":
		if !strings.HasPrefix(u.Path, "/images/") {
			return ""
		}
	default:
		return ""
	}
	u.RawQuery, u.Fragment = "", ""
	return u.String()
}

var posterClient = &http.Client{
	Timeout:       15 * time.Second,
	CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
}

// GET /api/films/poster?u= - a search answer's poster, through the server, as
// the page's own policy loads pictures from nowhere else.
func (s *Server) handleFilmPosterProxy(w http.ResponseWriter, r *http.Request) {
	addr := posterAllowed(r.URL.Query().Get("u"))
	if addr == "" {
		writeError(w, http.StatusBadRequest, "not a film poster")
		return
	}
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, addr, nil)
	if err != nil {
		writeError(w, http.StatusBadRequest, "not a film poster")
		return
	}
	resp, err := posterClient.Do(req)
	if err != nil {
		writeError(w, http.StatusBadGateway, "no poster")
		return
	}
	defer resp.Body.Close()
	ct := strings.ToLower(resp.Header.Get("Content-Type"))
	if resp.StatusCode != http.StatusOK || !(strings.HasPrefix(ct, "image/jpeg") || strings.HasPrefix(ct, "image/png") || strings.HasPrefix(ct, "image/webp")) {
		writeError(w, http.StatusBadGateway, "no poster")
		return
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Cache-Control", "private, max-age=86400")
	_, _ = io.Copy(w, io.LimitReader(resp.Body, 4<<20))
}

// PUT /api/films/{source}/{id}/poster - the owner's own picture as the film's
// poster, for everyone (Find the right film's last choice). The body is the
// picture, squared and shrunk on the device as any cover of one's own is.
func (s *Server) handleFilmPoster(w http.ResponseWriter, r *http.Request) {
	src, ok := s.reg.ByID(r.Context(), r.PathValue("source"))
	ps, can := src.(source.PosterSetter)
	if !ok || !can {
		writeError(w, http.StatusNotFound, "that library cannot take a picture")
		return
	}
	data, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 4<<20+1))
	if err != nil || len(data) == 0 || len(data) > 4<<20 {
		writeError(w, http.StatusRequestEntityTooLarge, "that picture is too big")
		return
	}
	ct := http.DetectContentType(data)
	if ct != "image/jpeg" && ct != "image/png" && ct != "image/webp" {
		writeError(w, http.StatusBadRequest, "that is not a picture")
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	if err := ps.SetPoster(ctx, r.PathValue("id"), data, ct); err != nil {
		s.log.Warn("film poster", "err", err)
		writeError(w, http.StatusBadGateway, "could not change it just now; try again")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"set": true})
}
