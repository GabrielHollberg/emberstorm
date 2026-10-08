package auth

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"testing"
)

// Over TLS the plain profile cookie is not this device's: any other install
// under the zone can set it for every name there, and an id planted that
// way was adopted by the next "keep me on this device" (the blind security
// review). Only the __Host- one, which no other site can set, counts.
func TestAPlantedProfileCookieIsNotTakenOverTLS(t *testing.T) {
	m := newManager(t)
	planted := "0123456789abcdef0123456789abcdef"

	r := httptest.NewRequest(http.MethodGet, "https://a.home.example/", nil)
	r.TLS = &tls.ConnectionState{}
	r.AddCookie(&http.Cookie{Name: ProfileCookieName, Value: planted})
	if got := m.ProfileDevice(r); got != "" {
		t.Fatalf("a plain profile cookie over TLS was taken: %q", got)
	}
	w := httptest.NewRecorder()
	m.EnsureProfileDevice(w, r)
	if c := w.Result().Cookies(); len(c) != 1 || c[0].Name != SecureProfileCookieName || c[0].Value == planted {
		t.Fatalf("no fresh __Host- cookie was given: %+v", c)
	}

	// The __Host- one counts, whichever comes first.
	r = httptest.NewRequest(http.MethodGet, "https://a.home.example/", nil)
	r.TLS = &tls.ConnectionState{}
	r.AddCookie(&http.Cookie{Name: ProfileCookieName, Value: planted})
	r.AddCookie(&http.Cookie{Name: SecureProfileCookieName, Value: "fedcba9876543210fedcba9876543210"})
	if m.ProfileDevice(r) == "" {
		t.Fatal("the __Host- profile cookie was not taken")
	}

	// Plain http keeps the plain one (a LAN address, where __Host- cannot be set).
	r = httptest.NewRequest(http.MethodGet, "http://192.168.0.2:8099/", nil)
	r.AddCookie(&http.Cookie{Name: ProfileCookieName, Value: planted})
	if m.ProfileDevice(r) == "" {
		t.Fatal("over plain http the profile cookie was not taken")
	}
}
