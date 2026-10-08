package names

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"
)

// zone is a fake of Porkbun's DNS API that holds records, so a sweep can be
// watched deciding what to keep.
type zone struct {
	mu      sync.Mutex
	domain  string
	records map[string]porkbunRecord // by id
	nextID  int
	deleted []string // names, in order
}

func newZone(t *testing.T) (*zone, *Porkbun) {
	t.Helper()
	z := &zone{domain: "soundstorm.dev", records: map[string]porkbunRecord{}, nextID: 1}
	srv := httptest.NewServer(z)
	t.Cleanup(srv.Close)
	return z, &Porkbun{Domain: z.domain, APIKey: "pk1_x", SecretAPIKey: "sk1_y", Base: srv.URL}
}

func (z *zone) add(name, typ, content, notes string) {
	z.mu.Lock()
	defer z.mu.Unlock()
	id := fmt.Sprint(z.nextID)
	z.nextID++
	full := z.domain
	if name != "" {
		full = name + "." + z.domain
	}
	z.records[id] = porkbunRecord{ID: id, Name: full, Type: typ, Content: content, Notes: notes}
}

func (z *zone) has(name, typ string) (porkbunRecord, bool) {
	z.mu.Lock()
	defer z.mu.Unlock()
	for _, r := range z.records {
		if r.Name == name+"."+z.domain && r.Type == typ {
			return r, true
		}
	}
	return porkbunRecord{}, false
}

func (z *zone) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	z.mu.Lock()
	defer z.mu.Unlock()
	raw, _ := io.ReadAll(r.Body)
	var body map[string]string
	json.Unmarshal(raw, &body)
	parts := strings.Split(strings.TrimPrefix(r.URL.Path, "/dns/"), "/")
	reply := map[string]any{"status": "SUCCESS"}

	match := func(typ, sub string) []porkbunRecord {
		var out []porkbunRecord
		for _, rec := range z.records {
			if rec.Type == typ && rec.Name == sub+"."+z.domain {
				out = append(out, rec)
			}
		}
		return out
	}
	switch parts[0] {
	case "retrieve":
		var all []porkbunRecord
		for _, rec := range z.records {
			all = append(all, rec)
		}
		reply["records"] = all
	case "retrieveByNameType":
		reply["records"] = match(parts[2], parts[3])
	case "create":
		id := fmt.Sprint(z.nextID)
		z.nextID++
		z.records[id] = porkbunRecord{ID: id, Name: body["name"] + "." + z.domain, Type: body["type"], Content: body["content"], Notes: body["notes"]}
	case "editByNameType":
		for _, rec := range match(parts[2], parts[3]) {
			rec.Content, rec.Notes = body["content"], body["notes"]
			z.records[rec.ID] = rec
		}
	case "deleteByNameType":
		for _, rec := range match(parts[2], parts[3]) {
			delete(z.records, rec.ID)
		}
	case "delete":
		if rec, ok := z.records[parts[2]]; ok {
			z.deleted = append(z.deleted, rec.Name)
			delete(z.records, parts[2])
		}
	}
	json.NewEncoder(w).Encode(reply)
}

// fakeID makes a valid install id - ten characters of lowercase base32 -
// from a prefix letter and a number, spelling the digits as letters.
func fakeID(prefix string, n int) string {
	return prefix + strings.NewReplacer("0", "a", "1", "b", "2", "c", "3", "d", "4", "e",
		"5", "f", "6", "g", "7", "h", "8", "i", "9", "j").Replace(fmt.Sprintf("%09d", n))
}

func daysAgo(n int) string {
	return seenPrefix + time.Now().UTC().AddDate(0, 0, -n).Format("2006-01-02")
}

func init() { sweepPause = 0 }

const halfYear = 180 * 24 * time.Hour

func TestASweepForgetsOnlyAbandonedInstalls(t *testing.T) {
	z, p := newZone(t)
	z.add("aaaaaaaaaa.home", "A", "192.168.0.10", daysAgo(200))      // abandoned
	z.add("bbbbbbbbbb.home", "A", "192.168.0.11", daysAgo(10))       // running
	z.add("cccccccccc.home", "AAAA", "fd00::1", daysAgo(400))        // abandoned, v6
	z.add("dddddddddd.home", "A", "192.168.0.12", "")                // from before stamps
	z.add("_acme-challenge.eeeeeeeeee.home", "TXT", "x", daysAgo(8)) // left by a crash
	z.add("_acme-challenge.ffffffffff.home", "TXT", "y", daysAgo(0)) // in flight
	// Not ours, however old: the apex, a website, the service's own name, a
	// name one character off the install pattern, and an install-shaped name
	// under some other label.
	z.add("", "A", "203.0.113.1", daysAgo(900))
	z.add("www", "CNAME", "example.net", daysAgo(900))
	z.add("names", "CNAME", "s2d2g1tg.up.railway.app", daysAgo(900))
	z.add("aaaaaaaaa.home", "A", "192.168.0.13", daysAgo(900))
	z.add("gggggggggg.other", "A", "192.168.0.14", daysAgo(900))
	for i := 0; i < 8; i++ { // enough healthy installs that two old ones are no alarm
		z.add(fakeID("h", i)+".home", "A", "192.168.1.1", daysAgo(1))
	}

	res, err := p.Sweep(context.Background(), "home", halfYear)
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	for _, gone := range []string{"aaaaaaaaaa.home.soundstorm.dev", "cccccccccc.home.soundstorm.dev", "_acme-challenge.eeeeeeeeee.home.soundstorm.dev"} {
		if !contains(z.deleted, gone) {
			t.Errorf("%s was kept; want it swept", gone)
		}
	}
	if len(z.deleted) != 3 {
		t.Errorf("deleted %v; want exactly the three stale records", z.deleted)
	}
	if res.Forgotten != 2 || res.Challenges != 1 || res.Unstamped != 1 {
		t.Errorf("result = %+v", res)
	}
}

// The valve. A sweep condemning a large share of installs at once is likelier
// a bug than a mass exodus, and being wrong costs every name together.
func TestASweepThatWouldRemoveTooManyRefuses(t *testing.T) {
	z, p := newZone(t)
	for i := 0; i < 40; i++ {
		z.add(fakeID("x", i)+".home", "A", "192.168.0.1", daysAgo(365))
	}

	_, err := p.Sweep(context.Background(), "home", halfYear)
	if err == nil || !strings.Contains(err.Error(), "refused") {
		t.Fatalf("err = %v, want a refusal", err)
	}
	if len(z.deleted) != 0 {
		t.Errorf("deleted %d records despite refusing", len(z.deleted))
	}
}

func TestASweepWindowShorterThanTheRestampIsRefused(t *testing.T) {
	_, p := newZone(t)
	if _, err := p.Sweep(context.Background(), "home", 7*24*time.Hour); err == nil {
		t.Error("a one-week window was accepted; every healthy install would look abandoned")
	}
}

// The question that decides whether sweeping is safe at all: a swept install
// that starts again gets the same name back, with no human involved.
func TestASweptInstallGetsItsNameBackWhenItReturns(t *testing.T) {
	z, p := newZone(t)
	s := &Server{Secret: []byte("0123456789abcdef0123456789abcdef"), Zone: "soundstorm.dev", Label: "home", DNS: p}
	srv := httptest.NewServer(s.Handler())
	defer srv.Close()
	c := &Client{Base: srv.URL}
	ctx := context.Background()

	reg, _ := c.Register(ctx)
	if err := c.SetAddress(ctx, reg, "192.168.0.50"); err != nil {
		t.Fatalf("SetAddress: %v", err)
	}
	// Seven months pass with the server switched off.
	p.Now = func() time.Time { return time.Now().AddDate(0, 7, 0) }
	for i := 0; i < 30; i++ { // other, healthy installs, so the valve stays shut
		z.add(fakeID("q", i)+".home", "A", "192.168.1.1", seenPrefix+p.now().UTC().Format("2006-01-02"))
	}
	if _, err := p.Sweep(ctx, "home", halfYear); err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	if _, ok := z.has(reg.ID+".home", "A"); ok {
		t.Fatal("the abandoned install's record survived the sweep")
	}

	// It starts again - same registration, nothing re-registered.
	if err := c.SetAddress(ctx, reg, "192.168.0.50"); err != nil {
		t.Fatalf("SetAddress after returning: %v", err)
	}
	rec, ok := z.has(reg.ID+".home", "A")
	if !ok || rec.Content != "192.168.0.50" {
		t.Fatalf("record after returning = %+v, %v; want the same name pointing home again", rec, ok)
	}
	if seen, ok := lastSeen(rec.Notes); !ok || seen.Format("2006-01-02") != p.now().UTC().Format("2006-01-02") {
		t.Errorf("the returning record is stamped %q, want today", rec.Notes)
	}
}

func contains(list []string, s string) bool {
	for _, v := range list {
		if v == s {
			return true
		}
	}
	return false
}

// panickySweeper panics instead of answering.
type panickySweeper struct{}

func (panickySweeper) Sweep(context.Context, string, time.Duration) (SweepResult, error) {
	panic("provider client fell over")
}

// RunSweeper is started with go, once, from main - nothing above it recovers
// a panic the way net/http does for a request. A bug in code that parses
// whatever a DNS provider's API answers today must not take the whole
// service down for every install being served at that moment.
func TestSweepRecoveredSurvivesAPanic(t *testing.T) {
	_, err := sweepRecovered(context.Background(), panickySweeper{}, "home", 90*24*time.Hour, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err == nil {
		t.Fatal("want an error describing the panic, got nil")
	}
	if !strings.Contains(err.Error(), "panicked") {
		t.Errorf("err = %v, want it to say it panicked", err)
	}
}

// A chosen name lasts while its install does, and an install keeps one: a
// name whose install was swept, or one held beside a newer, goes with its
// home and away names, and a challenge left for a chosen name goes too.
func TestASweepLetsGoOfNamesNobodyHolds(t *testing.T) {
	z, p := newZone(t)
	live, gone := fakeID("l", 1), fakeID("g", 2)
	z.add(live+".home", "A", "192.168.0.10", daysAgo(1))
	for i := 0; i < 8; i++ {
		z.add(fakeID("h", i)+".home", "A", "192.168.1.1", daysAgo(1))
	}
	z.add("kept.claim", "TXT", live, daysAgo(1))
	z.add("kept.home", "CNAME", live+".home.soundstorm.dev", daysAgo(1))
	z.add("older.claim", "TXT", live, daysAgo(40)) // the same install's earlier name
	z.add("older.home", "CNAME", live+".home.soundstorm.dev", daysAgo(40))
	z.add("orphan.claim", "TXT", gone, daysAgo(1)) // an install never announced
	z.add("orphan.home", "CNAME", gone+".home.soundstorm.dev", daysAgo(1))
	z.add("orphan.net", "CNAME", gone+".net.soundstorm.dev", daysAgo(1))
	z.add("_acme-challenge.orphan.home", "TXT", "z", daysAgo(9))

	res, err := p.Sweep(context.Background(), "home", halfYear)
	if err != nil {
		t.Fatalf("Sweep: %v", err)
	}
	for _, name := range []string{"older.claim", "older.home", "orphan.claim", "orphan.home", "orphan.net", "_acme-challenge.orphan.home"} {
		if !contains(z.deleted, name+".soundstorm.dev") {
			t.Errorf("%s was kept", name)
		}
	}
	for _, name := range []string{"kept.claim", "kept.home"} {
		if contains(z.deleted, name+".soundstorm.dev") {
			t.Errorf("%s was swept", name)
		}
	}
	if res.Names != 2 || res.Challenges != 1 {
		t.Errorf("result = %+v", res)
	}
}

// The away-names pass judged chosen names by the installs it could see, the
// ones with remote access, so an install without remote access lost its name
// every day and anybody could claim it, with a certificate for it (the
// blind security review). A chosen name stays while its install has a record
// under any label.
func TestTheAwayPassKeepsAHomeOnlyInstallsName(t *testing.T) {
	z, p := newZone(t)
	homeOnly, away := fakeID("o", 1), fakeID("w", 2)
	z.add(homeOnly+".home", "A", "192.168.0.10", daysAgo(1))
	z.add(away+".home", "A", "192.168.0.11", daysAgo(1))
	z.add(away+".net", "A", "203.0.113.9", daysAgo(1))
	z.add("smith.claim", "TXT", homeOnly, daysAgo(1))
	z.add("smith.home", "CNAME", homeOnly+".home.soundstorm.dev", daysAgo(1))
	z.add("jones.claim", "TXT", away, daysAgo(1))
	z.add("jones.home", "CNAME", away+".home.soundstorm.dev", daysAgo(1))
	z.add("jones.net", "CNAME", away+".net.soundstorm.dev", daysAgo(1))

	for _, label := range []string{"home", "net"} {
		if _, err := p.Sweep(context.Background(), label, halfYear); err != nil {
			t.Fatalf("Sweep %s: %v", label, err)
		}
	}
	for _, name := range []string{"smith.claim", "smith.home", "jones.claim", "jones.home", "jones.net"} {
		if contains(z.deleted, name+".soundstorm.dev") {
			t.Errorf("%s was swept, its install alive", name)
		}
	}
}
