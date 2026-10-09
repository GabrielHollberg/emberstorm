package httpapi

import (
	"net/http"
	"strings"
	"testing"
)

// The page's session check sends the sign-in cookie again, with the session's
// own end: a renewal answered to an app's player, which drops cookies, would
// otherwise leave the browser's cookie ending on its old day.
func TestTheSessionCheckSendsTheCookieAgain(t *testing.T) {
	h := newHarness(t)
	h.signUp(t)
	resp, _ := h.do(t, http.MethodGet, "/api/session", "")
	found := false
	for _, c := range resp.Header.Values("Set-Cookie") {
		if strings.Contains(c, "soundstorm_session=") && strings.Contains(c, "Expires=") {
			found = true
		}
	}
	if !found {
		t.Errorf("no session cookie sent with the session: %v", resp.Header.Values("Set-Cookie"))
	}
	// Signed out, nothing is sent.
	h.do(t, http.MethodPost, "/api/logout", "")
	resp, _ = h.do(t, http.MethodGet, "/api/session", "")
	for _, c := range resp.Header.Values("Set-Cookie") {
		if strings.Contains(c, "soundstorm_session=") && !strings.Contains(c, "Max-Age=0") && !strings.Contains(c, "soundstorm_session=;") {
			t.Errorf("a session cookie sent while signed out: %s", c)
		}
	}
}
