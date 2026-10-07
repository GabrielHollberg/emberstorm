package names

import (
	"context"
	"fmt"
	"html"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Finding a server from soundstorm.dev, two ways (the owner's asking: an
// address that starts with a random code is hard to get back to on a computer
// with no bookmark).
//
// "Open my SoundStorm": an install that allows it says, as it announces its
// address, which port it serves; the service notes which internet connection
// the announcement came from. A browser on soundstorm.dev then asks which
// installs announced from its own connection (GET /v1/find) and is sent to
// one. The note lives only in this process's memory - a cache, not a record:
// a restart forgets it, and installs re-announce twice a day, so it fills
// again by itself. Nothing is ever written down about where anybody is.
//
// A chosen name: an owner claims "hollberg", kept as a TXT record
// (hollberg.claim -> the install's id) where the install records are, so the
// service still keeps no database. hollberg.soundstorm.dev points here, and a
// small page sends a visitor on to the install - its home name from the same
// connection, its remote name from anywhere else. The certificate on the
// install is not involved (no names are added to it), so a chosen name costs
// nothing against Let's Encrypt's limits.

// findTTL is how long a noted connection is believed. An install announces at
// start and twice a day; three days rides out a few missed ones.
const findTTL = 72 * time.Hour

// findMax is the most installs one connection's answer names - a shared one
// (carrier-grade NAT) can have several, and a page needs only a handful.
const findMax = 8

var (
	findRate     = rate{60, time.Hour}       // per client network
	launchRate   = rate{240, time.Hour}      // per client network
	claimRate    = rate{6, 24 * time.Hour}   // per install
	globalClaims = rate{200, 24 * time.Hour} // everybody's
)

type found struct {
	id     string
	port   int
	lan    string
	public bool
	seen   time.Time
}

// findIndex is which installs announced from which connection, in memory.
type findIndex struct {
	mu   sync.Mutex
	byIP map[string]map[string]*found // connection -> id -> what it said
	byID map[string]string            // id -> connection, so a move forgets the old one
}

func newFindIndex() *findIndex {
	return &findIndex{byIP: map[string]map[string]*found{}, byID: map[string]string{}}
}

func (x *findIndex) note(conn, id string, port int, lan string, now time.Time) {
	x.mu.Lock()
	defer x.mu.Unlock()
	public := false
	if old, ok := x.byID[id]; ok {
		if e := x.byIP[old][id]; e != nil {
			public = e.public
		}
		if old != conn {
			delete(x.byIP[old], id)
			if len(x.byIP[old]) == 0 {
				delete(x.byIP, old)
			}
		}
	}
	if x.byIP[conn] == nil {
		x.byIP[conn] = map[string]*found{}
	}
	x.byIP[conn][id] = &found{id: id, port: port, lan: lan, public: public, seen: now}
	x.byID[id] = conn
	// A cap on the whole table: each entry is a live install, and the zone
	// holds 2,500 at most, so this is only a backstop against a flood.
	if len(x.byID) > 20000 {
		x.prune(now, findTTL/4)
	}
}

func (x *findIndex) forget(id string) {
	x.mu.Lock()
	defer x.mu.Unlock()
	if conn, ok := x.byID[id]; ok {
		delete(x.byIP[conn], id)
		if len(x.byIP[conn]) == 0 {
			delete(x.byIP, conn)
		}
		delete(x.byID, id)
	}
}

func (x *findIndex) setPublic(id string, on bool) {
	x.mu.Lock()
	defer x.mu.Unlock()
	if conn, ok := x.byID[id]; ok {
		if e := x.byIP[conn][id]; e != nil {
			e.public = on
		}
	}
}

// at is what announced from conn, newest first, at most findMax.
func (x *findIndex) at(conn string, now time.Time) []found {
	x.mu.Lock()
	defer x.mu.Unlock()
	var out []found
	for _, e := range x.byIP[conn] {
		if now.Sub(e.seen) < findTTL {
			out = append(out, *e)
		}
	}
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && out[j].seen.After(out[j-1].seen); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	if len(out) > findMax {
		out = out[:findMax]
	}
	return out
}

// lookup is what is known of an id: where it announced from, and whether it is
// fresh. ok is false when nothing is known (a restart since).
func (x *findIndex) lookup(id string, now time.Time) (found, string, bool) {
	x.mu.Lock()
	defer x.mu.Unlock()
	conn, ok := x.byID[id]
	if !ok {
		return found{}, "", false
	}
	e := x.byIP[conn][id]
	if e == nil || now.Sub(e.seen) >= findTTL {
		return found{}, "", false
	}
	return *e, conn, true
}

func (x *findIndex) prune(now time.Time, keep time.Duration) {
	for conn, ids := range x.byIP {
		for id, e := range ids {
			if now.Sub(e.seen) >= keep {
				delete(ids, id)
				delete(x.byID, id)
			}
		}
		if len(ids) == 0 {
			delete(x.byIP, conn)
		}
	}
}

// findConn is the connection a request came from, as the index keys it: an
// IPv4 address as it is, an IPv6 one by its /64 (a home is handed a whole
// /64, and its devices use different addresses in it).
func (s *Server) findConn(r *http.Request) string { return s.clientNet(r) }

// noteFind records an announcement (handleAddress), or forgets the install
// when it does not allow finding.
func (s *Server) noteFind(r *http.Request, id string, allow bool, port int, lan string) {
	if !allow || port < 1 || port > 65535 {
		s.find.forget(id)
		return
	}
	s.find.note(s.findConn(r), id, port, lan, time.Now())
}

// siteOrigin reports whether a browser's page is soundstorm.dev's own, which
// alone may read /v1/find.
func (s *Server) siteOrigin(origin string) bool {
	if origin == "" {
		return false
	}
	for _, o := range s.SiteOrigins {
		if strings.EqualFold(origin, o) {
			return true
		}
	}
	return false
}

// handleFind answers soundstorm.dev's "Open my SoundStorm": the home addresses
// of the installs that announced from the caller's own connection. Only ever
// the caller's own connection, never one it names - so it cannot be used to
// look up somebody else's.
func (s *Server) handleFind(w http.ResponseWriter, r *http.Request) {
	origin := r.Header.Get("Origin")
	if s.siteOrigin(origin) {
		w.Header().Set("Access-Control-Allow-Origin", origin)
		w.Header().Set("Vary", "Origin")
	}
	if r.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	if !s.limits.allow("find:"+s.findConn(r), findRate) {
		writeError(w, http.StatusTooManyRequests, "too many lookups; try again later")
		return
	}
	type server struct {
		URL string `json:"url"`
		LAN string `json:"lan,omitempty"`
	}
	out := []server{}
	for _, e := range s.find.at(s.findConn(r), time.Now()) {
		out = append(out, server{URL: s.homeURL(e.id, e.port), LAN: e.lan})
	}
	writeJSON(w, http.StatusOK, map[string]any{"servers": out})
}

func (s *Server) homeURL(id string, port int) string {
	return "https://" + s.NameFor(id) + portSuffix(port) + "/"
}

func (s *Server) remoteURL(id string, port int) string {
	return "https://" + s.PublicNameFor(id) + portSuffix(port) + "/"
}

func portSuffix(port int) string {
	if port == 0 || port == 443 {
		return ""
	}
	return ":" + strconv.Itoa(port)
}

// --- chosen names ----------------------------------------------------------------

// claimLabel is the level the claims are kept under: hollberg.claim.<zone>
// holds the id of the install that owns hollberg.<zone>.
const claimLabel = "claim"

var nameShape = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{1,28}[a-z0-9])$`)

// reservedNames are names the domain uses, or might, or that would mislead.
var reservedNames = map[string]bool{
	"www": true, "home": true, "net": true, "names": true, "name": true, "claim": true, "api": true,
	"app": true, "apps": true, "admin": true, "administrator": true, "docs": true, "doc": true,
	"help": true, "support": true, "status": true, "blog": true, "news": true, "shop": true,
	"store": true, "mail": true, "email": true, "smtp": true, "imap": true, "pop": true, "ftp": true,
	"ns": true, "ns1": true, "ns2": true, "dns": true, "cdn": true, "static": true, "assets": true,
	"dev": true, "test": true, "staging": true, "beta": true, "alpha": true, "demo": true,
	"login": true, "signin": true, "signup": true, "account": true, "accounts": true, "auth": true,
	"oauth": true, "sso": true, "root": true, "soundstorm": true, "official": true, "security": true,
	"abuse": true, "postmaster": true, "hostmaster": true, "webmaster": true, "info": true,
	"billing": true, "pay": true, "payment": true, "payments": true, "download": true,
	"downloads": true, "update": true, "updates": true, "relay": true, "backup": true, "box": true,
	"setup": true, "local": true, "localhost": true, "my": true, "go": true, "open": true,
	"find": true, "link": true, "invite": true, "team": true, "staff": true, "railway": true,
}

// NameStatus says why a name cannot be had, or "" when it can be claimed.
func NameStatus(name string) string {
	switch {
	case !nameShape.MatchString(name):
		return "Use 3 to 30 letters, numbers and dashes, starting and ending with a letter or number."
	case strings.Contains(name, "--"):
		return "No two dashes in a row."
	case reservedNames[name]:
		return "That name is kept for SoundStorm itself. Try another."
	case validID(name):
		return "That looks like a server's code. Try another."
	}
	return ""
}

// Getter is the provider's other half, for chosen names: what a name holds.
type Getter interface {
	Get(ctx context.Context, name, typ string) ([]string, error)
}

type claimCache struct {
	mu   sync.Mutex
	ids  map[string]claimEntry
	size int
}

type claimEntry struct {
	id   string
	when time.Time
}

func (c *claimCache) get(name string, now time.Time) (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	e, ok := c.ids[name]
	if !ok {
		return "", false
	}
	// A found name is believed ten minutes, a missing one one: a fresh claim
	// is visible soon, and a stream of made-up names cannot all be cached.
	ttl := 10 * time.Minute
	if e.id == "" {
		ttl = time.Minute
	}
	if now.Sub(e.when) > ttl {
		delete(c.ids, name)
		return "", false
	}
	return e.id, true
}

func (c *claimCache) put(name, id string, now time.Time) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.ids == nil || len(c.ids) > 5000 {
		c.ids = map[string]claimEntry{}
	}
	c.ids[name] = claimEntry{id: id, when: now}
}

// ownerOf is the id holding a chosen name, or "" when nobody does.
func (s *Server) ownerOf(ctx context.Context, name string) (string, error) {
	if id, ok := s.claims.get(name, time.Now()); ok {
		return id, nil
	}
	g, ok := s.DNS.(Getter)
	if !ok {
		return "", fmt.Errorf("chosen names are not available here")
	}
	vals, err := g.Get(ctx, name+"."+claimLabel, "TXT")
	if err != nil {
		return "", err
	}
	id := ""
	for _, v := range vals {
		if v = strings.Trim(v, `"`); validID(v) {
			id = v
			break
		}
	}
	s.claims.put(name, id, time.Now())
	return id, nil
}

// handleClaim gives the install a chosen name: PUT /v1/name {"name": "hollberg",
// "previous": "old"}. A name another install holds is refused; the previous
// name, if it is this install's, is let go.
func (s *Server) handleClaim(w http.ResponseWriter, r *http.Request, id string) {
	var body struct {
		Name     string `json:"name"`
		Previous string `json:"previous"`
	}
	if !readJSON(w, r, &body) {
		return
	}
	name := strings.ToLower(strings.TrimSpace(body.Name))
	if why := NameStatus(name); why != "" {
		writeError(w, http.StatusUnprocessableEntity, why)
		return
	}
	if _, ok := s.DNS.(Getter); !ok {
		writeError(w, http.StatusNotImplemented, "chosen names are not available on this name service")
		return
	}
	owner, err := s.ownerOf(r.Context(), name)
	if err != nil {
		s.Log.Error("look up a chosen name", "name", name, "err", err)
		writeError(w, http.StatusBadGateway, "could not check that name just now; try again")
		return
	}
	if owner != "" && owner != id {
		writeError(w, http.StatusConflict, "Somebody already has that name. Try another.")
		return
	}
	if owner == "" {
		if !s.limits.allow("claim:"+id, claimRate) || !s.limits.allow("claim:*", globalClaims) {
			writeError(w, http.StatusTooManyRequests, "Too many name changes today. Try again tomorrow.")
			return
		}
		if _, err := s.DNS.Set(r.Context(), name+"."+claimLabel, "TXT", id); err != nil {
			s.Log.Error("claim a name", "name", name, "err", err)
			writeError(w, http.StatusBadGateway, "the DNS provider refused the change")
			return
		}
		s.claims.put(name, id, time.Now())
		s.Log.Info("name claimed", "id", id, "name", name)
	}
	prev := strings.ToLower(strings.TrimSpace(body.Previous))
	if prev != "" && prev != name && nameShape.MatchString(prev) {
		s.release(r.Context(), id, prev)
	}
	writeJSON(w, http.StatusOK, map[string]string{"name": name, "url": "https://" + name + "." + s.Zone + "/"})
}

// handleRelease lets a chosen name go: DELETE /v1/name?name=hollberg.
func (s *Server) handleRelease(w http.ResponseWriter, r *http.Request, id string) {
	name := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("name")))
	if !nameShape.MatchString(name) {
		writeError(w, http.StatusUnprocessableEntity, "that is not a name")
		return
	}
	if !s.limits.allow("clear:"+id, clearRate) {
		writeError(w, http.StatusTooManyRequests, "too many changes for this install; try again later")
		return
	}
	s.release(r.Context(), id, name)
	w.WriteHeader(http.StatusNoContent)
}

// release takes a name away from id, only if id holds it.
func (s *Server) release(ctx context.Context, id, name string) {
	owner, err := s.ownerOf(ctx, name)
	if err != nil || owner != id {
		return
	}
	if err := s.DNS.Delete(ctx, name+"."+claimLabel, "TXT"); err != nil {
		s.Log.Warn("release a name", "name", name, "err", err)
		return
	}
	s.claims.put(name, "", time.Now())
	s.Log.Info("name released", "id", id, "name", name)
}

// chosenHost is the chosen name a request was made to - hollberg for
// hollberg.soundstorm.dev - or "" when it was made to the service's own name.
func (s *Server) chosenHost(r *http.Request) string {
	host := strings.ToLower(r.Host)
	if h, _, ok := strings.Cut(host, ":"); ok {
		host = h
	}
	label, ok := strings.CutSuffix(host, "."+s.Zone)
	if !ok || strings.Contains(label, ".") || reservedNames[label] || !nameShape.MatchString(label) {
		return ""
	}
	return label
}

// handleChosen is the page at a chosen name: it sends the visitor on to the
// install - the home name from the install's own connection, the remote name
// from anywhere else - or says plainly why it cannot.
func (s *Server) handleChosen(w http.ResponseWriter, r *http.Request, name string) {
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	if r.URL.Path != "/" {
		http.Redirect(w, r, "/", http.StatusFound)
		return
	}
	if !s.limits.allow("launch:"+s.findConn(r), launchRate) {
		chosenPage(w, http.StatusTooManyRequests, "Slow down a little", "Too many visits from here just now. Try again in a minute.", nil)
		return
	}
	id, err := s.ownerOf(r.Context(), name)
	if err != nil {
		chosenPage(w, http.StatusBadGateway, "Try again in a moment", "SoundStorm could not look that name up just now.", nil)
		return
	}
	if id == "" {
		chosenPage(w, http.StatusNotFound, "No SoundStorm by that name",
			"Nobody has chosen "+name+"."+s.Zone+". Check the spelling - or, at home, open soundstorm.dev and choose Open my SoundStorm.",
			[]link{{"Go to soundstorm.dev", "https://" + s.Zone + "/"}})
		return
	}
	e, conn, known := s.find.lookup(id, time.Now())
	port := e.port
	if port == 0 {
		port = 8099
	}
	switch {
	case known && conn == s.findConn(r):
		// The same internet connection as the server: at home.
		http.Redirect(w, r, s.homeURL(id, port), http.StatusFound)
	case known && e.public:
		http.Redirect(w, r, s.remoteURL(id, port), http.StatusFound)
	case known:
		chosenPage(w, http.StatusOK, "This SoundStorm is at home only",
			"You seem to be away from the house it is in, and it is not set up to be reached from outside. Open it from home - or ask its owner to turn on Reach it from anywhere in Settings.",
			[]link{{"Try it anyway", s.homeURL(id, port)}})
	default:
		// Nothing known yet (the service restarted): let the visitor say.
		chosenPage(w, http.StatusOK, "Where are you?",
			"Choose where you are, and SoundStorm opens the right address.",
			[]link{{"At home, on its Wi-Fi", s.homeURL(id, port)}, {"Away from home", s.remoteURL(id, port)}})
	}
}

type link struct{ label, href string }

func chosenPage(w http.ResponseWriter, status int, title, text string, links []link) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.WriteHeader(status)
	var b strings.Builder
	b.WriteString(`<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>`)
	b.WriteString(html.EscapeString(title))
	b.WriteString(` - SoundStorm</title><style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#000;color:#e8ebf0;font:16px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}main{max-width:420px;padding:32px 24px;text-align:center}h1{font-size:22px;margin:0 0 10px}p{color:#9aa3af;margin:0 0 22px}a{display:block;margin:10px 0;padding:12px 16px;border-radius:12px;background:#6aa8ff;color:#08131f;font-weight:700;text-decoration:none}a+a{background:#1f242d;color:#e8ebf0}</style></head><body><main><h1>`)
	b.WriteString(html.EscapeString(title))
	b.WriteString(`</h1><p>`)
	b.WriteString(html.EscapeString(text))
	b.WriteString(`</p>`)
	for _, l := range links {
		b.WriteString(`<a href="` + html.EscapeString(l.href) + `">` + html.EscapeString(l.label) + `</a>`)
	}
	b.WriteString(`</main></body></html>`)
	_, _ = w.Write([]byte(b.String()))
}
