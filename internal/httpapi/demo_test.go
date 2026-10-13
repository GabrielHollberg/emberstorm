package httpapi

import (
	"encoding/json"
	"net/http"
	"testing"
)

// The demo account plays and looks, keeps its place, favorites and playlists,
// and changes nothing else; the owner of a demo server is not held to it.
func TestTheDemoAccountChangesOnlyWhatIsPutBack(t *testing.T) {
	h := newHarness(t)
	h.signUp(t)
	h.api.demoUser = "demo"
	h.addMember(t, "demo", samPassword)
	demo := h.asUser(t, "demo", samPassword)

	_, body := demo.do(t, http.MethodGet, "/api/session", "")
	var session map[string]any
	_ = json.Unmarshal(body, &session)
	if session["demo"] != true {
		t.Errorf("the demo's session does not say demo: %s", body)
	}
	_, body = h.do(t, http.MethodGet, "/api/session", "")
	session = nil
	_ = json.Unmarshal(body, &session)
	if session["demo"] == true {
		t.Errorf("the owner's session says demo")
	}

	refusedAsDemo := func(resp *http.Response, body []byte) bool {
		var out map[string]any
		_ = json.Unmarshal(body, &out)
		return resp.StatusCode == http.StatusForbidden && out["demo"] == true
	}
	for _, c := range []struct{ method, path, body string }{
		{http.MethodPost, "/api/account/password", `{"current":"` + samPassword + `","password":"another long password"}`},
		{http.MethodPut, "/api/account/pin", `{"pin":"1234"}`},
		{http.MethodPut, "/api/upload?path=a.mp3&kind=music", "x"},
		{http.MethodPost, "/api/upload/plan", `{"paths":["a.mp3"]}`},
		{http.MethodPut, "/api/scrobble", `{"token":"x"}`},
		{http.MethodPost, "/api/photos/albums/abc/share", `{}`},
		{http.MethodPost, "/api/photos/send", `{}`},
		{http.MethodPost, "/api/voices/make", `{}`},
	} {
		resp, body := demo.do(t, c.method, c.path, c.body)
		if !refusedAsDemo(resp, body) {
			t.Errorf("%s %s by the demo: %d %s, want refused as a demo", c.method, c.path, resp.StatusCode, body)
		}
	}
	for _, c := range []struct{ method, path, body string }{
		{http.MethodPost, "/api/playlists", `{"name":"Road trip"}`},
		{http.MethodPatch, "/api/prefs", `{"coverStyle":"lyrics"}`},
		{http.MethodGet, "/api/playlists", ""},
	} {
		resp, body := demo.do(t, c.method, c.path, c.body)
		if refusedAsDemo(resp, body) {
			t.Errorf("%s %s by the demo was refused: %s", c.method, c.path, body)
		}
	}
	resp, body := h.do(t, http.MethodPost, "/api/playlists", `{"name":"Owner's"}`)
	if refusedAsDemo(resp, body) {
		t.Errorf("the owner was refused as a demo: %s", body)
	}
}
