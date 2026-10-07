package names

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

// fakeDNS answers what a name holds, as Porkbun does, for chosen names.
func (f *fakeDNS) Get(_ context.Context, name, typ string) ([]string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if v, ok := f.records[name+" "+typ]; ok {
		return []string{v}, nil
	}
	return nil, nil
}

// A service whose callers can be told apart by the X-Real-Ip header, as they
// are behind Railway's proxy, so "the same internet connection" can be tried.
func newFindService(t *testing.T) (*Server, *fakeDNS, string) {
	t.Helper()
	dns := newFakeDNS()
	s := &Server{
		Secret:         []byte("0123456789abcdef0123456789abcdef"),
		Zone:           "soundstorm.dev",
		Label:          "home",
		DNS:            dns,
		ClientIPHeader: "X-Real-Ip",
		SiteOrigins:    []string{"https://soundstorm.dev"},
	}
	srv := httptest.NewServer(s.Handler())
	t.Cleanup(srv.Close)
	return s, dns, srv.URL
}

// from is a client whose requests arrive from one home connection.
func from(base, ip string) *Client {
	return &Client{Base: base, HTTP: &http.Client{Transport: headerTransport{ip}}}
}

type headerTransport struct{ ip string }

func (h headerTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	r = r.Clone(r.Context())
	r.Header.Set("X-Real-Ip", h.ip)
	return http.DefaultTransport.RoundTrip(r)
}

func get(t *testing.T, base, path, ip, host string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, base+path, nil)
	req.Header.Set("X-Real-Ip", ip)
	req.Header.Set("Origin", "https://soundstorm.dev")
	if host != "" {
		req.Host = host
	}
	resp, err := (&http.Client{CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}).Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { resp.Body.Close() })
	return resp
}

func foundURLs(t *testing.T, base, ip string) []string {
	t.Helper()
	resp := get(t, base, "/v1/find", ip, "")
	if resp.Header.Get("Access-Control-Allow-Origin") != "https://soundstorm.dev" {
		t.Errorf("the website may not read the answer: CORS %q", resp.Header.Get("Access-Control-Allow-Origin"))
	}
	var out struct {
		Servers []struct{ URL string } `json:"servers"`
	}
	_ = json.NewDecoder(resp.Body).Decode(&out)
	var urls []string
	for _, s := range out.Servers {
		urls = append(urls, s.URL)
	}
	return urls
}

// "Open my SoundStorm": a browser finds the installs that announced from its
// own connection - only those that allow it, and never another connection's.
func TestABrowserFindsTheServerOnItsOwnConnection(t *testing.T) {
	_, _, base := newFindService(t)
	ctx := context.Background()
	home := from(base, "203.0.113.7")
	mine, _ := home.Register(ctx)
	hidden, _ := home.Register(ctx)
	elsewhere := from(base, "198.51.100.9")
	theirs, _ := elsewhere.Register(ctx)

	if err := home.Announce(ctx, mine, "192.168.0.50", 8099, true); err != nil {
		t.Fatal(err)
	}
	if err := home.Announce(ctx, hidden, "192.168.0.20", 8099, false); err != nil {
		t.Fatal(err)
	}
	if err := elsewhere.Announce(ctx, theirs, "192.168.1.5", 8099, true); err != nil {
		t.Fatal(err)
	}
	got := foundURLs(t, base, "203.0.113.7")
	want := "https://" + mine.ID + ".home.soundstorm.dev:8099/"
	if len(got) != 1 || got[0] != want {
		t.Errorf("from home found %v, want just %s", got, want)
	}
	if got := foundURLs(t, base, "192.0.2.1"); len(got) != 0 {
		t.Errorf("from a connection with no server found %v", got)
	}
	// Turned off in Settings: gone at the next announcement.
	_ = home.Announce(ctx, mine, "192.168.0.50", 8099, false)
	if got := foundURLs(t, base, "203.0.113.7"); len(got) != 0 {
		t.Errorf("after turning finding off, found %v", got)
	}
}

// A chosen name: claimed once, refused to another install, and its page sends
// a visitor to the home name from home, to the remote name from away when
// remote access is on, and says so plainly when it is not.
func TestAChosenNameLeadsToItsServer(t *testing.T) {
	s, dns, base := newFindService(t)
	ctx := context.Background()
	home := from(base, "203.0.113.7")
	mine, _ := home.Register(ctx)
	other, _ := home.Register(ctx)
	_ = home.Announce(ctx, mine, "192.168.0.50", 8099, true)

	url, err := home.ClaimName(ctx, mine, "TheHollbergs", "", "")
	if err != nil || url != "https://thehollbergs.soundstorm.dev/" {
		t.Fatalf("claim: %q, %v", url, err)
	}
	if dns.get("thehollbergs.claim TXT") != mine.ID {
		t.Errorf("claim record = %q", dns.get("thehollbergs.claim TXT"))
	}
	var se *StatusError
	if _, err := home.ClaimName(ctx, other, "thehollbergs", "", ""); !errors.As(err, &se) || se.Status != http.StatusConflict || se.Message != notAvailable {
		t.Errorf("a second install claiming it: %v, want 409 saying only it is not available", err)
	}
	// Held: single first and last names, the domain's own words, the product's
	// name, a server's code - all refused with the same words as a taken name.
	for _, name := range []string{"www", "smith", "maria", "hollberg", "sphere", "my-soundstorm", "abcdefghij"} {
		if _, err := home.ClaimName(ctx, other, name, "", ""); !errors.As(err, &se) || se.Status != http.StatusConflict || se.Message != notAvailable {
			t.Errorf("held %q: %v, want 409 saying only it is not available", name, err)
		}
	}
	// A held name the owner gave out: taken with its code, and only with it.
	s.HeldCodes = ParseHeldCodes(" Maria = family-code-1 , bad, =x")
	if _, err := home.ClaimName(ctx, other, "maria", "", "wrong"); !errors.As(err, &se) || se.Status != http.StatusConflict {
		t.Errorf("maria with the wrong code: %v", err)
	}
	// Capitals, spaces and dashes do not count.
	if _, err := home.ClaimName(ctx, other, "maria", "", " Family Code1 "); err != nil {
		t.Errorf("maria with its code typed loosely: %v", err)
	}

	host := "thehollbergs.soundstorm.dev"
	if r := get(t, base, "/", "203.0.113.7", host); r.StatusCode != http.StatusFound || r.Header.Get("Location") != "https://"+mine.ID+".home.soundstorm.dev:8099/" {
		t.Errorf("from home: %d to %q", r.StatusCode, r.Header.Get("Location"))
	}
	if r := get(t, base, "/", "198.51.100.9", host); r.StatusCode != http.StatusOK {
		t.Errorf("from away with remote access off: %d, want the page saying so", r.StatusCode)
	}
	s.find.setPublic(mine.ID, true)
	if r := get(t, base, "/", "198.51.100.9", host); r.StatusCode != http.StatusFound || r.Header.Get("Location") != "https://"+mine.ID+".net.soundstorm.dev:8099/" {
		t.Errorf("from away with remote access on: %d to %q", r.StatusCode, r.Header.Get("Location"))
	}
	if r := get(t, base, "/", "198.51.100.9", "nobody-here.soundstorm.dev"); r.StatusCode != http.StatusNotFound {
		t.Errorf("a name nobody has: %d", r.StatusCode)
	}
	// The service's own name still answers the API.
	if r := get(t, base, "/healthz", "198.51.100.9", "names.soundstorm.dev"); r.StatusCode != http.StatusOK {
		t.Errorf("the service's own name: %d", r.StatusCode)
	}

	// Moving to another name lets the first go, for anybody to take.
	if _, err := home.ClaimName(ctx, mine, "gabe-and-co", "thehollbergs", ""); err != nil {
		t.Fatal(err)
	}
	if dns.get("thehollbergs.claim TXT") != "" {
		t.Error("the old name was kept")
	}
	if _, err := home.ClaimName(ctx, other, "thehollbergs", "maria", ""); err != nil {
		t.Errorf("the freed name could not be taken: %v", err)
	}
	if err := home.ReleaseName(ctx, mine, "thehollbergs"); err != nil || dns.get("thehollbergs.claim TXT") != other.ID {
		t.Errorf("one install let go of another's name: %v, record %q", err, dns.get("thehollbergs.claim TXT"))
	}
}

func TestNameRules(t *testing.T) {
	for name, ok := range map[string]bool{
		"hollberg": true, "the-hollbergs": true, "a1b": true,
		"ab": false, "-x-y": false, "x--y": false, "UPPER": false,
		strings.Repeat("a", 31): false,
	} {
		if got := NameStatus(name) == ""; got != ok {
			t.Errorf("%q allowed = %v, want %v (%s)", name, got, ok, NameStatus(name))
		}
	}
}

// "Open my SoundStorm" on a phone: the app claims /open; without it the
// browser is sent on to the install's own address, and nowhere else.
func TestOpenSendsTheBrowserOnToTheServer(t *testing.T) {
	_, _, base := newFindService(t)
	for to, want := range map[string]string{
		"https://k3xqm2p7qa.home.soundstorm.dev:8099/":         "https://k3xqm2p7qa.home.soundstorm.dev:8099/",
		"https://K3XQM2P7QA.home.soundstorm.dev/x?y=1":         "https://k3xqm2p7qa.home.soundstorm.dev/",
		"https://evil.example/":                                "",
		"http://k3xqm2p7qa.home.soundstorm.dev/":               "",
		"https://k3xqm2p7qa.home.soundstorm.dev.evil.example/": "",
		"https://hollberg.soundstorm.dev/":                     "",
	} {
		r := get(t, base, "/open?to="+url.QueryEscape(to), "203.0.113.7", "")
		got := ""
		if r.StatusCode == http.StatusFound {
			got = r.Header.Get("Location")
		}
		if got != want {
			t.Errorf("%q: sent to %q (%d), want %q", to, got, r.StatusCode, want)
		}
	}
}
