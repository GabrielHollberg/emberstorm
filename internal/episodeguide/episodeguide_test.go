package episodeguide

import (
	"context"
	"net/http"
	"net/http/httptest"
	"testing"
)

// A show found by its IMDb number, through the guide's redirect, with its
// specials left out; and found by name when it has no ids.
func TestAShowsEpisodesAreFound(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/lookup/shows", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("imdb") != "tt0000555" {
			http.NotFound(w, r)
			return
		}
		http.Redirect(w, r, "https://elsewhere.example/shows/555", http.StatusMovedPermanently)
	})
	mux.HandleFunc("/singlesearch/shows", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"id":555}`))
	})
	mux.HandleFunc("/shows/555", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"name":"Harbor Lights","premiered":"2005-02-21","url":"https://www.tvmaze.com/shows/555",
			"_embedded":{"episodes":[
			{"name":"The Lighthouse Keeper","season":1,"number":1,"runtime":30,"airdate":"2005-02-21"},
			{"name":"A special","season":1,"number":null,"runtime":30},
			{"name":"The Tide Turns","season":1,"number":2,"runtime":30}]}}`))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	c := New(srv.URL)

	g, err := c.Find(context.Background(), map[string]string{"Imdb": "tt0000555"}, "Harbor")
	if err != nil {
		t.Fatal(err)
	}
	if g.Show != "Harbor Lights" || g.Year != "2005" || g.ByName || len(g.Episodes) != 2 {
		t.Fatalf("found %+v", g)
	}
	if e := g.Episodes[1]; e.Season != 1 || e.Episode != 2 || e.Name != "The Tide Turns" || e.Minutes != 30 {
		t.Errorf("second episode %+v", e)
	}
	g, err = c.Find(context.Background(), nil, "Harbor Lights")
	if err != nil || !g.ByName {
		t.Fatalf("by name: %+v %v", g, err)
	}
	if _, err := c.Find(context.Background(), map[string]string{"Imdb": "tt1"}, ""); err != ErrNotFound {
		t.Errorf("an unknown show: %v", err)
	}
}
