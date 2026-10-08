package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/GabrielHollberg/soundstorm/internal/names"
)

// The owner's web address and Open my EmberStorm: a name is claimed at the
// name service and kept, a taken one is refused with the service's words,
// clearing it lets it go, and turning finding off is saved and announced now.
// A member can do neither.
func TestTheOwnerChoosesAWebAddress(t *testing.T) {
	h := newRemoteHarness(t, &remoteState{available: true})
	claimed := map[string]string{} // name -> who
	var released []string
	announced := 0
	h.api.claimWebName = func(_ context.Context, name, previous, code string) (string, error) {
		if claimed[name] == "someone else" {
			return "", &names.StatusError{Status: http.StatusConflict, Message: "That name isn't available. Try another."}
		}
		if previous != "" {
			delete(claimed, previous)
		}
		claimed[name] = "me"
		return "https://" + name + ".soundstorm.dev/", nil
	}
	h.api.releaseWebName = func(_ context.Context, name string) error {
		released = append(released, name)
		delete(claimed, name)
		return nil
	}
	h.api.reannounce = func() { announced++ }
	claimed["taken"] = "someone else"
	h.signUp(t)

	session := func() map[string]any {
		_, body := h.do(t, http.MethodGet, "/api/session", "")
		var out map[string]any
		_ = json.Unmarshal(body, &out)
		return out
	}
	if s := session(); s["webNames"] != true || s["findable"] != true {
		t.Fatalf("the owner's session: webNames %v, findable %v", s["webNames"], s["findable"])
	}

	if resp, body := h.do(t, http.MethodPut, "/api/settings/web-name", `{"name":"Hollberg.soundstorm.dev"}`); resp.StatusCode != http.StatusOK || !strings.Contains(string(body), "https://hollberg.soundstorm.dev/") {
		t.Fatalf("claiming: %d %s", resp.StatusCode, body)
	}
	if s := session(); s["webName"] != "hollberg" {
		t.Errorf("kept as %v", s["webName"])
	}
	if resp, body := h.do(t, http.MethodPut, "/api/settings/web-name", `{"name":"taken"}`); resp.StatusCode != http.StatusBadRequest || !strings.Contains(string(body), "isn't available") {
		t.Errorf("a taken name: %d %s", resp.StatusCode, body)
	}
	if resp, _ := h.do(t, http.MethodPut, "/api/settings/web-name", `{"name":"no spaces"}`); resp.StatusCode != http.StatusBadRequest {
		t.Errorf("a name written wrong: %d", resp.StatusCode)
	}
	if s := session(); s["webName"] != "hollberg" {
		t.Errorf("a refused claim changed the address to %v", s["webName"])
	}
	if resp, _ := h.do(t, http.MethodPut, "/api/settings/web-name", `{"name":""}`); resp.StatusCode != http.StatusOK || len(released) != 1 || released[0] != "hollberg" {
		t.Errorf("clearing: %d, released %v", resp.StatusCode, released)
	}
	if _, has := session()["webName"]; has {
		t.Error("still has an address after clearing it")
	}

	if resp, _ := h.do(t, http.MethodPut, "/api/settings/findable", `{"enabled":false}`); resp.StatusCode != http.StatusOK || announced != 1 {
		t.Errorf("turning finding off: %d, announced %d times", resp.StatusCode, announced)
	}
	if s := session(); s["findable"] != false {
		t.Errorf("findable after turning it off: %v", s["findable"])
	}

	// A member can do neither.
	h.addMember(t, "alice", samPassword)
	member := h.asUser(t, "alice", samPassword)
	for _, path := range []string{"/api/settings/web-name", "/api/settings/findable"} {
		if code, _ := member.do(t, http.MethodPut, path, `{"name":"mine","enabled":true}`); code.StatusCode != http.StatusForbidden {
			t.Errorf("a member at %s: %d, want 403", path, code.StatusCode)
		}
	}
}
