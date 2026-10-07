package jellyfin

import (
	"context"
	"net/url"
	"sync"

	"github.com/GabrielHollberg/soundstorm/internal/source"
)

// A film in two files ("Dune (2021) - part1.mkv", "- part2.mkv" in its own
// folder) is one film to Jellyfin: the film is the first part, and the rest
// are "additional parts" - items of their own that no search or lookup
// returns, only GET /Videos/{id}/AdditionalParts (checked against 12.1.0 on
// the owner's Long Road North, 2026-10-07). Tidy film names put halves this
// way (library/filmnames.go), so the player plays them one after another.

// partsOf remembers which film each later part belongs to, as learnt from
// the film: what lets a part be played, as the film may be.
type partsOf struct {
	mu sync.Mutex
	m  map[string]string // part id -> film id
}

func (p *partsOf) filmOf(id string) (string, bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	film, ok := p.m[id]
	return film, ok
}

func (p *partsOf) note(part, film string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.m == nil || len(p.m) > 4096 {
		p.m = map[string]string{}
	}
	p.m[part] = film
}

// filmParts is a film's parts, its own first, or nil for a film in one file
// (or a part itself). firstTicks is the film's own length.
func (s *Source) filmParts(ctx context.Context, itemID string, firstTicks int64) []source.VideoPart {
	if _, isPart := s.parts.filmOf(itemID); isPart || s.searchType() != "Movie" {
		return nil
	}
	params := url.Values{}
	if s.cfg.UserID != "" {
		params.Set("userId", s.cfg.UserID)
	}
	var resp itemsResponse
	if err := s.http.JSON(ctx, "/Videos/"+url.PathEscape(itemID)+"/AdditionalParts", params, &resp); err != nil || len(resp.Items) == 0 {
		return nil
	}
	out := []source.VideoPart{{ID: itemID, Seconds: float64(firstTicks) / ticksPerSecond}}
	for _, it := range resp.Items {
		if it.ID == "" || it.ID == itemID {
			continue
		}
		s.parts.note(it.ID, itemID)
		out = append(out, source.VideoPart{ID: it.ID, Seconds: float64(it.RunTimeTicks) / ticksPerSecond})
	}
	if len(out) < 2 {
		return nil
	}
	return out
}
