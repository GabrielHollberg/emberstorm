package jellyfin

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"strings"

	"github.com/GabrielHollberg/soundstorm/internal/httpx"
	"github.com/GabrielHollberg/soundstorm/internal/source"
)

// FindMatches asks Jellyfin which film (or show, for the television source)
// an item might be, by name and year: its own "Identify", over its online
// providers (TheMovieDb, the Open Movie Database). Checked against 12.1.0:
// POST /Items/RemoteSearch/Movie with the item's id answers a list, each
// with Name, ProductionYear, ImageUrl and ProviderIds. The same film from
// two providers is given once, the first (TheMovieDb's) kept.
func (s *Source) FindMatches(ctx context.Context, itemID, name string, year int) ([]source.FilmMatch, error) {
	if err := s.owns(ctx, itemID); err != nil {
		return nil, err
	}
	info := map[string]any{"Name": name}
	if year > 0 {
		info["Year"] = year
	}
	resp, err := s.http.Do(ctx, httpx.Request{
		Method: http.MethodPost,
		Path:   "/Items/RemoteSearch/" + s.searchType(),
		Body:   map[string]any{"SearchInfo": info, "ItemId": itemID},
	})
	if err != nil {
		return nil, fmt.Errorf("jellyfin %q: search for a film: %w", s.id, err)
	}
	if err := resp.Err(); err != nil {
		return nil, fmt.Errorf("jellyfin %q: search for a film: %w", s.id, err)
	}
	var raws []json.RawMessage
	if err := resp.JSON(&raws); err != nil {
		return nil, fmt.Errorf("jellyfin %q: search for a film: %w", s.id, err)
	}
	seen := map[string]bool{}
	var out []source.FilmMatch
	for _, raw := range raws {
		var r struct {
			Name           string `json:"Name"`
			ProductionYear int    `json:"ProductionYear"`
			Overview       string `json:"Overview"`
			ImageURL       string `json:"ImageUrl"`
		}
		if json.Unmarshal(raw, &r) != nil || strings.TrimSpace(r.Name) == "" {
			continue
		}
		key := strings.ToLower(r.Name) + "|" + fmt.Sprint(r.ProductionYear)
		if seen[key] {
			continue
		}
		seen[key] = true
		poster := r.ImageURL
		if u, err := url.Parse(poster); err != nil || u.Scheme != "https" {
			poster = ""
		}
		out = append(out, source.FilmMatch{
			Name: r.Name, Year: r.ProductionYear, Overview: r.Overview,
			Poster: poster, Raw: raw,
		})
		if len(out) == 12 {
			break
		}
	}
	return out, nil
}

// ApplyMatch tells Jellyfin the item is this film: POST
// /Items/RemoteSearch/Apply/{id} with the answer as it was found, every image
// replaced. It then fetches the details and poster itself, in a moment.
func (s *Source) ApplyMatch(ctx context.Context, itemID string, m source.FilmMatch) error {
	if err := s.owns(ctx, itemID); err != nil {
		return err
	}
	if len(m.Raw) == 0 {
		return fmt.Errorf("jellyfin %q: nothing to apply", s.id)
	}
	resp, err := s.http.Do(ctx, httpx.Request{
		Method: http.MethodPost,
		Path:   "/Items/RemoteSearch/Apply/" + url.PathEscape(itemID),
		Params: url.Values{"ReplaceAllImages": {"true"}},
		Body:   json.RawMessage(m.Raw),
	})
	if err != nil {
		return fmt.Errorf("jellyfin %q: apply a film: %w", s.id, err)
	}
	if err := resp.Err(); err != nil {
		return fmt.Errorf("jellyfin %q: apply a film: %w", s.id, err)
	}
	s.shelf.Clear()
	return nil
}

// searchType is what Jellyfin's remote search calls this source's items.
func (s *Source) searchType() string {
	if strings.Contains(s.itemTypes, "Series") {
		return "Series"
	}
	return "Movie"
}
