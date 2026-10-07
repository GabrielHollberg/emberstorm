package names

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// The Android app's Digital Asset Links: what lets a camera open a TV's
// sign-in code in the app. Its package and fingerprint, nothing else.
func TestAssetLinksNameTheApp(t *testing.T) {
	s := &Server{Secret: make([]byte, 32), Zone: "soundstorm.dev", Label: "home", AndroidCerts: []string{"AA:BB"}}
	rec := httptest.NewRecorder()
	s.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, "/.well-known/assetlinks.json", nil))
	var got []struct {
		Relation []string `json:"relation"`
		Target   struct {
			Namespace   string   `json:"namespace"`
			PackageName string   `json:"package_name"`
			Fingerprint []string `json:"sha256_cert_fingerprints"`
		} `json:"target"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || rec.Code != http.StatusOK || len(got) != 1 {
		t.Fatalf("%d %s %v", rec.Code, rec.Body, err)
	}
	if got[0].Target.PackageName != "dev.soundstorm.app" || got[0].Target.Fingerprint[0] != "AA:BB" ||
		got[0].Relation[0] != "delegate_permission/common.handle_all_urls" {
		t.Fatalf("%+v", got[0])
	}
	if ct := rec.Header().Get("Content-Type"); ct != "application/json" && ct != "application/json; charset=utf-8" {
		t.Fatalf("content type %q", ct)
	}
}

// The iPhone app's apple-app-site-association: its id, and only the TV
// sign-in and invitation paths - served at both the address iOS asks first
// and the old one.
func TestAppleLinksNameTheApp(t *testing.T) {
	s := &Server{Secret: make([]byte, 32), Zone: "soundstorm.dev", Label: "home", AppleApps: []string{"TEAM.dev.soundstorm.app"}}
	for _, path := range []string{"/.well-known/apple-app-site-association", "/apple-app-site-association"} {
		rec := httptest.NewRecorder()
		s.Handler().ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		var got struct {
			Applinks struct {
				Details []struct {
					AppIDs     []string            `json:"appIDs"`
					Components []map[string]string `json:"components"`
				} `json:"details"`
			} `json:"applinks"`
		}
		if err := json.Unmarshal(rec.Body.Bytes(), &got); err != nil || rec.Code != http.StatusOK || len(got.Applinks.Details) != 1 {
			t.Fatalf("%s: %d %s %v", path, rec.Code, rec.Body, err)
		}
		d := got.Applinks.Details[0]
		if d.AppIDs[0] != "TEAM.dev.soundstorm.app" || len(d.Components) != 3 ||
			d.Components[0]["/"] != "/link/*" || d.Components[1]["/"] != "/invite/*" || d.Components[2]["/"] != "/open" {
			t.Fatalf("%+v", d)
		}
		if ct := rec.Header().Get("Content-Type"); ct != "application/json" && ct != "application/json; charset=utf-8" {
			t.Fatalf("content type %q", ct)
		}
	}
}
