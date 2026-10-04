package httpapi

import (
	"encoding/json"
	"net/http"
	"strings"
	"testing"
)

func playerJSON(t *testing.T, body []byte) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("decode %s: %v", body, err)
	}
	return out
}

// Nathan's phone and the owner's TV: he may play on it only by taking it
// over; while it plays it asks first; a No holds him off; a free TV switches
// to him and then plays what he sent.
func TestPlayingOnSomebodyElsesTV(t *testing.T) {
	h := newHarness(t)
	h.signUp(t) // gabe, on the TV
	if resp, body := h.do(t, http.MethodPost, "/api/users", `{"username":"nathan","password":"violet tractor glacier"}`); resp.StatusCode != http.StatusOK {
		t.Fatalf("adding nathan: %d %s", resp.StatusCode, body)
	}
	phone := h.another(t)
	if code, _ := signInAs(t, phone, "nathan", "violet tractor glacier"); code != http.StatusOK {
		t.Fatalf("nathan signs in: %d", code)
	}
	tv := "aaaaaaaaaaaaaaaa1111"
	if resp, body := h.do(t, http.MethodPost, "/api/players/hello", `{"id":"`+tv+`","name":"Living room TV","tv":true}`); resp.StatusCode != http.StatusOK {
		t.Fatalf("hello: %d %s", resp.StatusCode, body)
	}
	// gabe's laptop: not a TV, never shown to nathan.
	h.do(t, http.MethodPost, "/api/players/hello", `{"id":"bbbbbbbbbbbbbbbb2222","name":"Laptop"}`)
	h.do(t, http.MethodPost, "/api/players/"+tv+"/state", `{"playing":true,"title":"Dune"}`)

	_, body := phone.do(t, http.MethodGet, "/api/players", "")
	if strings.Contains(string(body), "Laptop") || !strings.Contains(string(body), "Living room TV") || strings.Contains(string(body), "Dune") {
		t.Fatalf("nathan's list: %s", body)
	}
	// Controlling it without taking it over: refused.
	if resp, _ := phone.do(t, http.MethodPost, "/api/players/"+tv+"/command", `{"type":"control","action":"pause"}`); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("nathan paused gabe's TV: %d", resp.StatusCode)
	}
	// Playing on it while gabe watches: asked on the TV.
	resp, body := phone.do(t, http.MethodPost, "/api/players/"+tv+"/command", `{"type":"play","item":{"sourceId":"x","id":"1"}}`)
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("taking over a busy TV should ask: %d %s", resp.StatusCode, body)
	}
	ask := playerJSON(t, body)["asking"].(string)
	_, body = h.do(t, http.MethodGet, "/api/players/"+tv+"/next", "")
	if !strings.Contains(string(body), `"ask"`) || !strings.Contains(string(body), "nathan") {
		t.Fatalf("the TV should be asked: %s", body)
	}
	h.do(t, http.MethodPost, "/api/players/"+tv+"/ask/"+ask, `{"allow":false}`)
	_, body = phone.do(t, http.MethodGet, "/api/players/"+tv+"/ask/"+ask, "")
	if playerJSON(t, body)["denied"] != true {
		t.Fatalf("a No should come back: %s", body)
	}
	if resp, _ := phone.do(t, http.MethodPost, "/api/players/"+tv+"/command", `{"type":"play","item":{"sourceId":"x","id":"1"}}`); resp.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("asking again at once should wait: %d", resp.StatusCode)
	}

	// A TV that is free switches to nathan, then plays what he sent.
	tv2 := "cccccccccccccccc3333"
	h.do(t, http.MethodPost, "/api/players/hello", `{"id":"`+tv2+`","name":"Bedroom TV","tv":true}`)
	resp, body = phone.do(t, http.MethodPost, "/api/players/"+tv2+"/command", `{"type":"play","item":{"sourceId":"x","id":"2"}}`)
	if resp.StatusCode != http.StatusOK || playerJSON(t, body)["switched"] != true {
		t.Fatalf("a free TV should switch: %d %s", resp.StatusCode, body)
	}
	// The TV is still gabe's session until it switches: it gets the code.
	_, body = h.do(t, http.MethodGet, "/api/players/"+tv2+"/next", "")
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("next: %s", body)
	}
	var next struct {
		Commands []map[string]any `json:"commands"`
	}
	_ = json.Unmarshal(body, &next)
	// The switch alone: the page is made again as nathan, and what he sent
	// waits for it.
	if len(next.Commands) != 1 || next.Commands[0]["type"] != "switch" {
		t.Fatalf("the TV should be told to switch first, alone: %s", body)
	}
	code := next.Commands[0]["code"].(string)
	resp, body = h.do(t, http.MethodPost, "/api/players/switch", `{"code":"`+code+`","id":"`+tv2+`"}`)
	if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "nathan") {
		t.Fatalf("switching: %d %s", resp.StatusCode, body)
	}
	if _, body := h.do(t, http.MethodGet, "/api/players/"+tv2+"/next", ""); !strings.Contains(string(body), `"play"`) {
		t.Fatalf("then what nathan sent: %s", body)
	}
	// The TV is nathan's now: his phone sees what it plays, and may pause it.
	h.do(t, http.MethodPost, "/api/players/hello", `{"id":"`+tv2+`","name":"Bedroom TV","tv":true}`)
	h.do(t, http.MethodPost, "/api/players/"+tv2+"/state", `{"playing":true,"title":"Nathan's film"}`)
	if _, body := phone.do(t, http.MethodGet, "/api/players/"+tv2, ""); !strings.Contains(string(body), "Nathan's film") || playerJSON(t, body)["mine"] != true {
		t.Fatalf("nathan's TV now: %s", body)
	}
	if resp, _ := phone.do(t, http.MethodPost, "/api/players/"+tv2+"/command", `{"type":"control","action":"pause"}`); resp.StatusCode != http.StatusOK {
		t.Fatalf("nathan pauses his TV: %d", resp.StatusCode)
	}
	// A code is used once.
	if resp, _ := h.do(t, http.MethodPost, "/api/players/switch", `{"code":"`+code+`","id":"`+tv2+`"}`); resp.StatusCode != http.StatusForbidden {
		t.Fatalf("a switch code used twice: %d", resp.StatusCode)
	}

	// Choosing a device in the picker (claim) plays nothing: his own TV is
	// simply his to control, and a free TV of somebody else's switches to him
	// with nothing waiting behind the switch but the claim itself.
	if resp, body := phone.do(t, http.MethodPost, "/api/players/"+tv2+"/command", `{"type":"claim"}`); resp.StatusCode != http.StatusOK {
		t.Fatalf("claiming his own TV: %d %s", resp.StatusCode, body)
	}
	// (The client that redeemed the switch is nathan now: gabe's TV is
	// another client, signed in as him.)
	den := h.another(t)
	if code, _ := signInAs(t, den, "gabe", "correct horse"); code != http.StatusOK {
		t.Fatalf("gabe signs in on the den TV: %d", code)
	}
	tv3 := "dddddddddddddddd4444"
	den.do(t, http.MethodPost, "/api/players/hello", `{"id":"`+tv3+`","name":"Den TV","tv":true}`)
	resp, body = phone.do(t, http.MethodPost, "/api/players/"+tv3+"/command", `{"type":"claim"}`)
	if resp.StatusCode != http.StatusOK || playerJSON(t, body)["switched"] != true {
		t.Fatalf("claiming a free TV should switch it: %d %s", resp.StatusCode, body)
	}
	if _, body := den.do(t, http.MethodGet, "/api/players/"+tv3+"/next", ""); !strings.Contains(string(body), `"switch"`) {
		t.Fatalf("the claimed TV should be told to switch: %s", body)
	}
}

// Let in, the phone sends its music at once - before the TV has signed in
// as it. That waits behind the switch; it used to become a second question,
// and the music never came.
func TestWhatIsSentAsATVSwitchesWaitsForIt(t *testing.T) {
	h := newHarness(t)
	h.signUp(t)
	if resp, body := h.do(t, http.MethodPost, "/api/users", `{"username":"nathan","password":"violet tractor glacier"}`); resp.StatusCode != http.StatusOK {
		t.Fatalf("adding nathan: %d %s", resp.StatusCode, body)
	}
	phone := h.another(t)
	if code, _ := signInAs(t, phone, "nathan", "violet tractor glacier"); code != http.StatusOK {
		t.Fatalf("nathan signs in: %d", code)
	}
	tv := "eeeeeeeeeeeeeeee5555"
	h.do(t, http.MethodPost, "/api/players/hello", `{"id":"`+tv+`","name":"Apple TV","tv":true}`)
	h.do(t, http.MethodPost, "/api/players/"+tv+"/state", `{"playing":true,"title":"Dune"}`)
	resp, body := phone.do(t, http.MethodPost, "/api/players/"+tv+"/command", `{"type":"claim"}`)
	if resp.StatusCode != http.StatusAccepted {
		t.Fatalf("a busy TV should ask: %d %s", resp.StatusCode, body)
	}
	ask := playerJSON(t, body)["asking"].(string)
	h.do(t, http.MethodGet, "/api/players/"+tv+"/next", "")
	h.do(t, http.MethodPost, "/api/players/"+tv+"/ask/"+ask, `{"allow":true}`)
	if _, body := phone.do(t, http.MethodGet, "/api/players/"+tv+"/ask/"+ask, ""); playerJSON(t, body)["allowed"] != true {
		t.Fatalf("yes should come back: %s", body)
	}
	resp, body = phone.do(t, http.MethodPost, "/api/players/"+tv+"/command", `{"type":"play","item":{"sourceId":"x","id":"song"}}`)
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("music sent as the TV switches: %d %s", resp.StatusCode, body)
	}
	_, body = h.do(t, http.MethodGet, "/api/players/"+tv+"/next", "")
	var next struct {
		Commands []map[string]any `json:"commands"`
	}
	_ = json.Unmarshal(body, &next)
	if len(next.Commands) != 1 || next.Commands[0]["type"] != "switch" {
		t.Fatalf("the switch first: %s", body)
	}
	h.do(t, http.MethodPost, "/api/players/switch", `{"code":"`+next.Commands[0]["code"].(string)+`","id":"`+tv+`"}`)
	_, body = h.do(t, http.MethodGet, "/api/players/"+tv+"/next", "")
	if !strings.Contains(string(body), `"song"`) || strings.Contains(string(body), `"ask"`) {
		t.Fatalf("then the music, not another question: %s", body)
	}
}

// Two phones of one person: A controls B, then B chooses A. The newer choice
// wins - A is told to let go of B - or each sends the other's music back for
// ever.
func TestTwoPhonesDoNotControlEachOther(t *testing.T) {
	h := newHarness(t)
	h.signUp(t)
	a, b := "aaaaaaaaaaaaaaaa7777", "bbbbbbbbbbbbbbbb8888"
	h.do(t, http.MethodPost, "/api/players/hello", `{"id":"`+a+`","name":"Phone A"}`)
	h.do(t, http.MethodPost, "/api/players/hello", `{"id":"`+b+`","name":"Phone B"}`)
	send := func(from, to, body string) {
		t.Helper()
		req, _ := http.NewRequest(http.MethodPost, h.srv.URL+"/api/players/"+to+"/command", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("X-Soundstorm-Player", from)
		resp, err := h.client.Do(req)
		if err != nil || resp.StatusCode != http.StatusOK {
			t.Fatalf("command %s to %s: %v %v", from, to, err, resp)
		}
		resp.Body.Close()
	}
	send(a, b, `{"type":"claim"}`)
	send(a, b, `{"type":"play","item":{"sourceId":"x","id":"song"}}`)
	h.do(t, http.MethodGet, "/api/players/"+b+"/next", "")
	// B now chooses A.
	send(b, a, `{"type":"claim"}`)
	_, body := h.do(t, http.MethodGet, "/api/players/"+a+"/next", "")
	if !strings.Contains(string(body), `"released"`) || !strings.Contains(string(body), b) {
		t.Fatalf("A should be told to let go of B: %s", body)
	}
	// And only once: B choosing A again tells A nothing more.
	send(b, a, `{"type":"control","action":"pause"}`)
	if _, body := h.do(t, http.MethodGet, "/api/players/"+a+"/next", ""); strings.Contains(string(body), `"released"`) {
		t.Fatalf("told twice: %s", body)
	}
}
