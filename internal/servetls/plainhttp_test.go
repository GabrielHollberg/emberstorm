package servetls

import (
	"crypto/tls"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestPlainHTTPFromOutsideIsSentToHTTPS(t *testing.T) {
	s := &Server{sniff: true}
	h := s.OnlyHomeOverHTTP(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	}))
	ask := func(method, host, path string, secure bool) *httptest.ResponseRecorder {
		r := httptest.NewRequest(method, "http://x"+path, nil)
		r.Host = host
		if secure {
			r.TLS = &tls.ConnectionState{}
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}
	for _, host := range []string{
		"192.168.0.50:8099", "10.0.0.2:8099", "localhost:8099", "127.0.0.1",
		"[fe80::1]:8099", "[fd00::5]:8099", "100.101.102.103:8099",
		"emberstorm.local", "em-7k4p-xq2m.local:80", "soundstorm-app:8080",
		"desktop-pc:8099", "box.lan:8099", "server.tail1234.ts.net",
	} {
		if w := ask("GET", host, "/", false); w.Code != http.StatusTeapot {
			t.Errorf("%s over http: %d, want it served", host, w.Code)
		}
	}
	for _, host := range []string{
		"k3x9m2p7qa.net.emberstorm.app:8099", "k3x9m2p7qa.home.emberstorm.app:8099",
		"yourname.emberstorm.app", "203.0.113.7:8099", "[2001:db8::1]:8099",
	} {
		w := ask("GET", host, "/api/session?x=1", false)
		if w.Code != http.StatusPermanentRedirect || w.Header().Get("Location") != "https://"+host+"/api/session?x=1" {
			t.Errorf("%s over http: %d %q, want sent to https", host, w.Code, w.Header().Get("Location"))
		}
		if w := ask("POST", host, "/api/login", false); w.Code != http.StatusForbidden {
			t.Errorf("POST to %s over http: %d, want refused", host, w.Code)
		}
		if w := ask("GET", host, "/", true); w.Code != http.StatusTeapot {
			t.Errorf("%s over https: %d, want served", host, w.Code)
		}
	}
	// The names service checks reachability over plain http, at the public
	// address, and follows no redirect.
	if w := ask("GET", "203.0.113.7:8099", "/api/remote-reachable", false); w.Code != http.StatusTeapot {
		t.Errorf("the reachability check: %d, want served", w.Code)
	}
	// Not serving both on one port, nothing changes.
	plain := (*Server)(nil).OnlyHomeOverHTTP(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusTeapot)
	}))
	r := httptest.NewRequest("GET", "http://203.0.113.7/", nil)
	w := httptest.NewRecorder()
	plain.ServeHTTP(w, r)
	if w.Code != http.StatusTeapot {
		t.Errorf("without TLS: %d, want served", w.Code)
	}
}
