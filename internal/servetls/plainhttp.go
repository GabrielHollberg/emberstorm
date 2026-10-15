package servetls

import (
	"net"
	"net/http"
	"net/netip"
	"strings"

	"github.com/GabrielHollberg/soundstorm/internal/names"
)

// OnlyHomeOverHTTP sends a plain-http request on to https unless the address
// it was made to only works inside the house. The one port speaks both
// (Listener), and with remote access on the router forwards both: without
// this, http://<the home's public address>:8099, or the away name typed with
// http://, showed the sign-in page unencrypted to the internet, a password
// crossing it in the clear (the security review, 2026-10-14).
//
// It goes by the address typed, not by who asks: under Docker Desktop every
// connection arrives from Docker's own gateway, so where a visitor really is
// cannot be told. From outside the house only the internet-facing addresses
// reach the server at all, and those are exactly the ones moved to https.
//
// Kept on plain http: home addresses and names (a new install is first
// opened at its LAN address, before it has a certificate), and the names
// service's reachability check, which asks over plain http and follows no
// redirect. Only GET and HEAD are moved; anything else is refused, as its
// body has already crossed in the clear.
func (s *Server) OnlyHomeOverHTTP(h http.Handler) http.Handler {
	if !s.Sniffs() {
		return h
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.TLS != nil || homeOnly(r.Host) || r.URL.Path == names.ReachablePath {
			h.ServeHTTP(w, r)
			return
		}
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "This address works only over https.", http.StatusForbidden)
			return
		}
		w.Header().Set("Cache-Control", "no-store")
		http.Redirect(w, r, "https://"+r.Host+r.URL.RequestURI(), http.StatusPermanentRedirect)
	})
}

// homeOnly reports whether an address (a Host header, port or not) is one
// that reaches the server only from inside the house: a private, loopback or
// link-local address, Tailscale's 100.64/10, a name with no dot, or a name
// under a suffix only a home network answers.
func homeOnly(hostport string) bool {
	host := hostport
	if h, _, err := net.SplitHostPort(hostport); err == nil {
		host = h
	}
	host = strings.TrimSuffix(strings.ToLower(strings.Trim(host, "[]")), ".")
	if host == "" {
		return true // an HTTP/1.0 request with no Host: nothing to send it to
	}
	if a, err := netip.ParseAddr(host); err == nil {
		a = a.Unmap()
		return a.IsPrivate() || a.IsLoopback() || a.IsLinkLocalUnicast() ||
			a.IsUnspecified() || netip.MustParsePrefix("100.64.0.0/10").Contains(a)
	}
	if !strings.Contains(host, ".") {
		return true
	}
	for _, suffix := range []string{".local", ".lan", ".home", ".home.arpa", ".internal", ".localhost", ".ts.net"} {
		if strings.HasSuffix(host, suffix) {
			return true
		}
	}
	return false
}
