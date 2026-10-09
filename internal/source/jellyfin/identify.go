package jellyfin

import (
	"context"
	"encoding/base64"
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

// Posters lists the posters Jellyfin's online providers have for an item it
// has identified: GET /Items/{id}/RemoteImages?type=Primary, every language,
// each with its Url, ProviderName, size and Language. Only addresses a browser
// may be shown through the server are kept (the caller checks), 60 at most.
func (s *Source) Posters(ctx context.Context, itemID string) ([]source.PosterChoice, error) {
	if err := s.owns(ctx, itemID); err != nil {
		return nil, err
	}
	resp, err := s.http.Do(ctx, httpx.Request{
		Method: http.MethodGet,
		Path:   "/Items/" + url.PathEscape(itemID) + "/RemoteImages",
		Params: url.Values{"type": {"Primary"}, "includeAllLanguages": {"true"}, "limit": {"200"}},
	})
	if err != nil {
		return nil, fmt.Errorf("jellyfin %q: list posters: %w", s.id, err)
	}
	if err := resp.Err(); err != nil {
		return nil, fmt.Errorf("jellyfin %q: list posters: %w", s.id, err)
	}
	var body struct {
		Images []struct {
			URL          string `json:"Url"`
			ProviderName string `json:"ProviderName"`
			Width        int    `json:"Width"`
			Height       int    `json:"Height"`
			Language     string `json:"Language"`
		} `json:"Images"`
	}
	if err := resp.JSON(&body); err != nil {
		return nil, fmt.Errorf("jellyfin %q: list posters: %w", s.id, err)
	}
	seen := map[string]bool{}
	var out []source.PosterChoice
	for _, im := range body.Images {
		u, err := url.Parse(im.URL)
		if err != nil || u.Scheme != "https" || seen[im.URL] {
			continue
		}
		seen[im.URL] = true
		out = append(out, source.PosterChoice{
			URL: im.URL, Provider: im.ProviderName, Width: im.Width, Height: im.Height, Language: im.Language,
		})
	}
	return out, nil
}

// ChoosePoster has Jellyfin fetch one of those posters and make it the
// item's: POST /Items/{id}/RemoteImages/Download?type=Primary&imageUrl=.
func (s *Source) ChoosePoster(ctx context.Context, itemID string, p source.PosterChoice) error {
	if err := s.owns(ctx, itemID); err != nil {
		return err
	}
	params := url.Values{"type": {"Primary"}, "imageUrl": {p.URL}}
	if p.Provider != "" {
		params.Set("providerName", p.Provider)
	}
	resp, err := s.http.Do(ctx, httpx.Request{
		Method: http.MethodPost,
		Path:   "/Items/" + url.PathEscape(itemID) + "/RemoteImages/Download",
		Params: params,
	})
	if err != nil {
		return fmt.Errorf("jellyfin %q: choose a poster: %w", s.id, err)
	}
	if err := resp.Err(); err != nil {
		return fmt.Errorf("jellyfin %q: choose a poster: %w", s.id, err)
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

// SetPoster makes a picture the item's poster: POST
// /Items/{id}/Images/Primary with the picture base64-encoded as the body -
// Jellyfin's own shape for an uploaded image, not multipart.
func (s *Source) SetPoster(ctx context.Context, itemID string, image []byte, contentType string) error {
	if err := s.owns(ctx, itemID); err != nil {
		return err
	}
	enc := make([]byte, base64.StdEncoding.EncodedLen(len(image)))
	base64.StdEncoding.Encode(enc, image)
	resp, err := s.http.Do(ctx, httpx.Request{
		Method:  http.MethodPost,
		Path:    "/Items/" + url.PathEscape(itemID) + "/Images/Primary",
		Raw:     enc,
		RawType: contentType,
	})
	if err != nil {
		return fmt.Errorf("jellyfin %q: set a poster: %w", s.id, err)
	}
	if err := resp.Err(); err != nil {
		return fmt.Errorf("jellyfin %q: set a poster: %w", s.id, err)
	}
	s.shelf.Clear()
	return nil
}
