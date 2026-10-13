package httpapi

import (
	"net/http"
	"strings"

	"github.com/GabrielHollberg/soundstorm/internal/state"
)

// A public demo server (2026-10-13, the owner's asking: the app stores'
// reviewers must sign in and use the apps, and they cannot set up a server;
// it also lets anybody try EmberStorm before installing). One install apart
// from every other, its media free to show, put back as it was every night
// (scripts/demo-stack.sh), with one account anybody may sign in as -
// SOUNDSTORM_DEMO_USER.
//
// That account looks at and plays everything, and changes only what the
// night's reset puts back anyway and nobody else sees: where it got to,
// favorites, playlists, albums of its own, the queue, playing on a TV. Every
// other change is refused - uploads, deleting, moving, its password, PIN or
// picture, photo backup and imports, sending photos, making audiobooks,
// scrobbling, sign-ins to Plex - with "This is a demo". An allowlist, not a
// denylist: a route added later is refused to the demo until somebody
// decides it is harmless. The account is a member, so the owner's routes
// were never open to it.

// isDemo is whether this account is the demo's. Never the owner, whatever
// it is called: the owner keeps their own private account on a demo.
func (s *Server) isDemo(u state.User) bool {
	return s.demoUser != "" && !u.IsOwner() && strings.EqualFold(u.Name, s.demoUser)
}

// demoChanges are the writes the demo account may make, by method and the
// start of the path.
var demoChanges = []struct{ method, prefix string }{
	{"PUT", "/api/playback/"},     // where a film, song or book got to
	{"PUT", "/api/book/progress"}, // where a book got to
	{"POST", "/api/history"},      // a song counted as played
	{"POST", "/api/music/radio"},  // the next songs of a station
	{"POST", "/api/scrobble/now"}, // "playing now", sent nowhere without a token
	{"POST", "/api/players/"},     // this device as a player, and playing on a TV
	{"PUT", "/api/favorites"},
	{"DELETE", "/api/favorites"},
	{"POST", "/api/playlists"}, // making, adding to, moving and importing
	{"PATCH", "/api/playlists/"},
	{"DELETE", "/api/playlists/"},
	{"PATCH", "/api/prefs"},        // the order of the pills, the look, the speed
	{"POST", "/api/photos/albums"}, // albums of its own (sharing refused below)
	{"PATCH", "/api/photos/albums/"},
	{"DELETE", "/api/photos/albums/"},
	{"POST", "/api/link/code/"},       // signing a TV in, as the demo
	{"POST", "/api/devices/pending/"}, // answering "allow this sign-in?"
}

func demoMayChange(r *http.Request) bool {
	if r.Method == http.MethodGet || r.Method == http.MethodHead {
		return true
	}
	path := r.URL.Path
	// Sharing an album is with somebody else.
	if strings.HasPrefix(path, "/api/photos/albums/") && strings.Contains(path, "/share") {
		return false
	}
	for _, c := range demoChanges {
		if r.Method == c.method && strings.HasPrefix(path, c.prefix) {
			return true
		}
	}
	return false
}
