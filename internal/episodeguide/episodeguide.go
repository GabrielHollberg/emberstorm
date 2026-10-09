// Package episodeguide asks TVmaze, a free episode guide that needs no key
// or account, for a show's episodes - their names and lengths - so the owner
// numbering a ripped disc can see which file is which episode (the owner's
// asking, 2026-10-09). Only when the owner taps for it: it says to an outside
// service which show this is, by its IMDb or TheTVDB number, else its name.
//
// The answer is a guide, never an instruction: nothing is renamed by it.
package episodeguide

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	userAgent = "EmberStorm (https://github.com/GabrielHollberg/soundstorm)"
	maxBody   = 4 << 20
	keep      = 24 * time.Hour
)

// Episode is one episode as the guide lists it. Minutes is the guide's
// runtime, which is often the slot (30 for a 23-minute cartoon), so it tells
// a double episode or an extra apart, never one episode from the next.
type Episode struct {
	Season  int    `json:"season"`
	Episode int    `json:"episode"`
	Name    string `json:"name"`
	Minutes int    `json:"minutes,omitempty"`
	Aired   string `json:"aired,omitempty"`
}

// Guide is a show as the guide knows it.
type Guide struct {
	Show     string    `json:"show"`
	Year     string    `json:"year,omitempty"`
	URL      string    `json:"url,omitempty"`
	ByName   bool      `json:"byName,omitempty"` // found by its name alone: may be another show
	Episodes []Episode `json:"episodes"`
}

// ErrNotFound means the guide does not know the show.
var ErrNotFound = errors.New("the episode guide does not know this show")

// Client asks TVmaze. The zero value is not usable; use New.
type Client struct {
	base string
	http *http.Client

	mu    sync.Mutex
	cache map[string]cached
}

type cached struct {
	g    Guide
	when time.Time
}

// New makes a client for base ("" for TVmaze's own API).
func New(base string) *Client {
	if base == "" {
		base = "https://api.tvmaze.com"
	}
	return &Client{
		base: strings.TrimRight(base, "/"),
		http: &http.Client{
			Timeout: 15 * time.Second,
			// A lookup answers with a redirect to the show; its address is
			// read, not followed, so nothing goes anywhere else.
			CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		},
		cache: map[string]cached{},
	}
}

// Find looks a show up by its ids (Jellyfin's provider ids: "Imdb", "Tvdb"),
// else by name.
func (c *Client) Find(ctx context.Context, ids map[string]string, name string) (Guide, error) {
	key := ids["Imdb"] + "|" + ids["Tvdb"] + "|" + strings.ToLower(name)
	c.mu.Lock()
	if v, ok := c.cache[key]; ok && time.Since(v.when) < keep {
		c.mu.Unlock()
		return v.g, nil
	}
	c.mu.Unlock()

	showID, byName := 0, false
	for _, look := range []struct{ param, value string }{{"imdb", ids["Imdb"]}, {"thetvdb", ids["Tvdb"]}} {
		if look.value == "" || len(look.value) > 20 {
			continue
		}
		id, err := c.lookup(ctx, look.param, look.value)
		if err != nil && !errors.Is(err, ErrNotFound) {
			return Guide{}, err
		}
		if id > 0 {
			showID = id
			break
		}
	}
	if showID == 0 {
		if name = strings.TrimSpace(name); name == "" || len(name) > 200 {
			return Guide{}, ErrNotFound
		}
		var hit struct {
			ID int `json:"id"`
		}
		if err := c.get(ctx, "/singlesearch/shows?"+url.Values{"q": {name}}.Encode(), &hit); err != nil {
			return Guide{}, err
		}
		if hit.ID <= 0 {
			return Guide{}, ErrNotFound
		}
		showID, byName = hit.ID, true
	}

	var show struct {
		Name      string `json:"name"`
		Premiered string `json:"premiered"`
		URL       string `json:"url"`
		Embedded  struct {
			Episodes []struct {
				Name    string `json:"name"`
				Season  int    `json:"season"`
				Number  *int   `json:"number"`
				Runtime *int   `json:"runtime"`
				Airdate string `json:"airdate"`
			} `json:"episodes"`
		} `json:"_embedded"`
	}
	if err := c.get(ctx, "/shows/"+strconv.Itoa(showID)+"?embed=episodes", &show); err != nil {
		return Guide{}, err
	}
	g := Guide{Show: show.Name, ByName: byName, Episodes: []Episode{}}
	if len(show.Premiered) >= 4 {
		g.Year = show.Premiered[:4]
	}
	if strings.HasPrefix(show.URL, "https://www.tvmaze.com/") {
		g.URL = show.URL
	}
	for i, e := range show.Embedded.Episodes {
		if i >= 5000 {
			break
		}
		if e.Number == nil || *e.Number <= 0 || e.Season < 0 {
			continue // a special, numbered nowhere
		}
		ep := Episode{Season: e.Season, Episode: *e.Number, Name: cut(e.Name, 200), Aired: cut(e.Airdate, 10)}
		if e.Runtime != nil && *e.Runtime > 0 && *e.Runtime < 1000 {
			ep.Minutes = *e.Runtime
		}
		g.Episodes = append(g.Episodes, ep)
	}
	c.mu.Lock()
	if len(c.cache) > 200 {
		c.cache = map[string]cached{}
	}
	c.cache[key] = cached{g, time.Now()}
	c.mu.Unlock()
	return g, nil
}

// lookup turns an id into TVmaze's show number, from where its answer sends us.
func (c *Client) lookup(ctx context.Context, param, value string) (int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+"/lookup/shows?"+url.Values{param: {value}}.Encode(), nil)
	if err != nil {
		return 0, err
	}
	req.Header.Set("User-Agent", userAgent)
	resp, err := c.http.Do(req)
	if err != nil {
		return 0, fmt.Errorf("the episode guide did not answer")
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64<<10))
	switch {
	case resp.StatusCode == http.StatusNotFound:
		return 0, ErrNotFound
	case resp.StatusCode >= 300 && resp.StatusCode < 400:
		return showNumber(resp.Header.Get("Location"))
	default:
		return 0, fmt.Errorf("the episode guide answered %d", resp.StatusCode)
	}
}

// showNumber reads the 555 out of ".../shows/555".
func showNumber(loc string) (int, error) {
	i := strings.LastIndex(loc, "/shows/")
	if i < 0 {
		return 0, ErrNotFound
	}
	n, err := strconv.Atoi(strings.TrimRight(loc[i+len("/shows/"):], "/"))
	if err != nil || n <= 0 {
		return 0, ErrNotFound
	}
	return n, nil
}

func (c *Client) get(ctx context.Context, path string, into any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.base+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", userAgent)
	req.Header.Set("Accept", "application/json")
	resp, err := c.http.Do(req)
	if err != nil {
		return fmt.Errorf("the episode guide did not answer")
	}
	defer resp.Body.Close()
	if resp.StatusCode == http.StatusNotFound {
		return ErrNotFound
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("the episode guide answered %d", resp.StatusCode)
	}
	if err := json.NewDecoder(io.LimitReader(resp.Body, maxBody)).Decode(into); err != nil {
		return fmt.Errorf("the episode guide's answer could not be read")
	}
	return nil
}

func cut(s string, n int) string {
	if len(s) <= n {
		return s
	}
	for n > 0 && !utf8Start(s[n]) {
		n--
	}
	return s[:n]
}

func utf8Start(b byte) bool { return b&0xC0 != 0x80 }
