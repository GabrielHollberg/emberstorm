package httpapi

import "testing"

// The server fetches a search's poster itself, so only a film database's
// picture is fetched - never an address that leads anywhere else.
func TestOnlyAFilmDatabasesPosterIsFetched(t *testing.T) {
	for in, want := range map[string]string{
		"https://image.tmdb.org/t/p/original/aP8.jpg":        "https://image.tmdb.org/t/p/w342/aP8.jpg",
		"https://m.media-amazon.com/images/M/MV5B.jpg":       "https://m.media-amazon.com/images/M/MV5B.jpg",
		"http://image.tmdb.org/t/p/original/aP8.jpg":         "",
		"https://image.tmdb.org:8443/t/p/original/a.jpg":     "",
		"https://user@image.tmdb.org/t/p/original/a.jpg":     "",
		"https://image.tmdb.org/other/a.jpg":                 "",
		"https://jellyfin:8096/System/Info":                  "",
		"https://image.tmdb.org.evil.example/t/p/w342/a.jpg": "",
	} {
		if got := posterAllowed(in); got != want {
			t.Errorf("%q: got %q, want %q", in, got, want)
		}
	}
}
