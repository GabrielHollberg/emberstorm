package jellyfin

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// "Find the right film": the search is Jellyfin's, the same film from two
// providers is offered once, and choosing sends back exactly what was found.
func TestAFilmIsMatchedByHand(t *testing.T) {
	var applied []byte
	var replace string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/Items":
			_ = json.NewEncoder(w).Encode(map[string]any{"Items": []any{map[string]any{"Id": r.URL.Query().Get("Ids")}}})
		case "/Items/RemoteSearch/Movie":
			io.WriteString(w, `[
				{"Name":"The Quiet Meridian","ProductionYear":2002,"ImageUrl":"https://image.tmdb.org/t/p/original/a.jpg","ProviderIds":{"Tmdb":"2501"}},
				{"Name":"The Glass Harbor","ProductionYear":2004,"ImageUrl":"http://insecure.example/b.jpg"},
				{"Name":"The Quiet Meridian","ProductionYear":2002,"ProviderIds":{"Imdb":"tt0258463"}}]`)
		case "/Items/RemoteSearch/Apply/film-1":
			applied, _ = io.ReadAll(r.Body)
			replace = r.URL.Query().Get("ReplaceAllImages")
			w.WriteHeader(http.StatusNoContent)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	s, err := New(Config{ID: "jellyfin", BaseURL: srv.URL, Token: "t", UserID: "u"})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	found, err := s.FindMatches(ctx, "film-1", "The Quiet Meridian", 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(found) != 2 || found[0].Year != 2002 || found[0].Poster == "" || found[1].Poster != "" {
		t.Fatalf("found %+v", found)
	}
	if err := s.ApplyMatch(ctx, "film-1", found[0]); err != nil {
		t.Fatal(err)
	}
	var back map[string]any
	if json.Unmarshal(applied, &back) != nil || back["ProviderIds"].(map[string]any)["Tmdb"] != "2501" || replace != "true" {
		t.Errorf("applied %s (replace %q)", applied, replace)
	}
}

// A film in two files plays as one: Playback lists both parts, the second is
// playable though Jellyfin's lookups never return it, and its files are both.
func TestAFilmInPartsIsOneFilm(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/Items" && r.URL.Query().Get("Ids") == "film-1":
			io.WriteString(w, `{"Items":[{"Id":"film-1"}]}`)
		case r.URL.Path == "/Items":
			io.WriteString(w, `{"Items":[]}`) // a part: hidden from lookups
		case r.URL.Path == "/Videos/film-1/AdditionalParts":
			io.WriteString(w, `{"Items":[{"Id":"part-2","RunTimeTicks":72000000000,"Path":"/media/movies/Dune (2021)/Dune (2021) - part2.mkv"}]}`)
		case r.URL.Path == "/Users/u/Items/film-1":
			io.WriteString(w, `{"Path":"/media/movies/Dune (2021)/Dune (2021) - part1.mkv"}`)
		case r.URL.Path == "/Items/film-1/PlaybackInfo" || r.URL.Path == "/Items/part-2/PlaybackInfo":
			io.WriteString(w, `{"MediaSources":[{"Id":"ms","Container":"mp4","SupportsDirectPlay":true,"RunTimeTicks":60000000000}]}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	s, err := New(Config{ID: "jellyfin", BaseURL: srv.URL, Token: "t", UserID: "u", MediaRoot: "/media/movies"})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	pb, err := s.Playback(ctx, "film-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(pb.Parts) != 2 || pb.Parts[0].Seconds != 6000 || pb.Parts[1].ID != "part-2" || pb.Parts[1].Seconds != 7200 {
		t.Fatalf("parts %+v", pb.Parts)
	}
	if _, err := s.Playback(ctx, "part-2"); err != nil {
		t.Errorf("the second part could not be played: %v", err)
	}
	if _, err := s.Playback(ctx, "someone-else"); err == nil {
		t.Error("an item that is no part of a film was played")
	}
	files, err := s.ItemFiles(ctx, "film-1")
	if err != nil || len(files) != 2 {
		t.Errorf("files %v, %v", files, err)
	}
}

// The owner's own picture as a poster goes to Jellyfin base64-encoded, its
// own shape for an uploaded image.
func TestTheOwnersPictureBecomesThePoster(t *testing.T) {
	var got []byte
	var ct string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/Items":
			w.Header().Set("Content-Type", "application/json")
			io.WriteString(w, `{"Items":[{"Id":"film-1"}]}`)
		case "/Items/film-1/Images/Primary":
			got, _ = io.ReadAll(r.Body)
			ct = r.Header.Get("Content-Type")
			w.WriteHeader(http.StatusNoContent)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	s, _ := New(Config{ID: "jellyfin", BaseURL: srv.URL, Token: "t", UserID: "u"})
	if err := s.SetPoster(context.Background(), "film-1", []byte("\xff\xd8\xffpicture"), "image/jpeg"); err != nil {
		t.Fatal(err)
	}
	if string(got) != "/9j/cGljdHVyZQ==" || ct != "image/jpeg" {
		t.Errorf("sent %q as %q", got, ct)
	}
}

// Choose a poster: Jellyfin's posters for a title, the insecure and repeated
// ones left out, and the one chosen fetched by Jellyfin itself.
func TestAPosterIsChosen(t *testing.T) {
	var chosen, provider string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/Items":
			_ = json.NewEncoder(w).Encode(map[string]any{"Items": []any{map[string]any{"Id": r.URL.Query().Get("Ids")}}})
		case "/Items/show-1/RemoteImages":
			if r.URL.Query().Get("type") != "Primary" {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			io.WriteString(w, `{"Images":[
				{"ProviderName":"TheMovieDb","Url":"https://image.tmdb.org/t/p/original/a.jpg","Width":2000,"Height":3000,"Language":"en"},
				{"ProviderName":"TheMovieDb","Url":"https://image.tmdb.org/t/p/original/a.jpg"},
				{"ProviderName":"Other","Url":"http://insecure.example/b.jpg"},
				{"ProviderName":"TheMovieDb","Url":"https://image.tmdb.org/t/p/original/c.jpg","Language":"de"}],"TotalRecordCount":4}`)
		case "/Items/show-1/RemoteImages/Download":
			chosen, provider = r.URL.Query().Get("imageUrl"), r.URL.Query().Get("providerName")
			w.WriteHeader(http.StatusNoContent)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	t.Cleanup(srv.Close)
	s, err := New(Config{ID: "jellyfin-tv", BaseURL: srv.URL, Token: "t", UserID: "u", ItemTypes: "Series,Episode"})
	if err != nil {
		t.Fatal(err)
	}
	ctx := context.Background()
	posters, err := s.Posters(ctx, "show-1")
	if err != nil {
		t.Fatal(err)
	}
	if len(posters) != 2 || posters[0].Width != 2000 || posters[1].Language != "de" {
		t.Fatalf("posters %+v", posters)
	}
	if err := s.ChoosePoster(ctx, "show-1", posters[1]); err != nil {
		t.Fatal(err)
	}
	if chosen != "https://image.tmdb.org/t/p/original/c.jpg" || provider != "TheMovieDb" {
		t.Errorf("chose %q from %q", chosen, provider)
	}
}
