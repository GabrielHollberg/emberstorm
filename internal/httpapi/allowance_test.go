package httpapi

import (
	"fmt"
	"sync"
	"testing"
	"time"

	"github.com/GabrielHollberg/soundstorm/internal/state"
)

// An allowance forgets those it has nothing against, so a table keyed by
// address does not grow with every address that ever asked - and keeps
// those it does.
func TestAnAllowanceForgetsTheFull(t *testing.T) {
	var a allowance
	now := time.Now()
	for range 3 {
		a.allow("busy", now, 3, time.Minute)
	}
	if a.allow("busy", now, 3, time.Minute) {
		t.Fatal("a fourth in a burst of three")
	}
	for i := range allowanceKeep {
		a.allow(fmt.Sprint("addr", i), now, 3, time.Minute)
	}
	later := now.Add(4 * time.Minute)
	a.allow("newcomer", later, 3, time.Minute)
	if n := len(a.left); n > 2 {
		t.Fatalf("still holding %d", n)
	}
	a.left["busy"] = playBucket{tokens: 0, at: later}
	if a.allow("busy", later, 3, time.Minute) {
		t.Fatal("a refusal was forgotten")
	}
}

// An artist's "more" link is only ever a Wikipedia article.
func TestTheBioLinkIsWikipediasOnly(t *testing.T) {
	for raw, want := range map[string]bool{
		"https://en.wikipedia.org/wiki/Radiohead": true,
		"https://pt-br.wikipedia.org/wiki/X":      true,
		"http://en.wikipedia.org/wiki/X":          false,
		"javascript:alert(1)":                     false,
		"https://en.wikipedia.org.evil.example/":  false,
		"https://evil.example/?en.wikipedia.org":  false,
		"https://a@en.wikipedia.org/wiki/X":       false,
	} {
		if got := wikipediaPage(raw) != ""; got != want {
			t.Errorf("%s: %v", raw, got)
		}
	}
}

// Uploads at once are held against the photo limit as they start, so 64 of
// them cannot all pass on the same figure.
func TestUploadsAtOnceStayWithinThePhotoLimit(t *testing.T) {
	h := newHarness(t)
	h.signUp(t)
	member, err := h.api.store.AddUser(state.User{ID: "m1", Name: "alice"})
	if err != nil {
		t.Fatal(err)
	}
	one := 1
	if err := h.api.store.SetPhotoLimitGB(member.ID, &one); err != nil {
		t.Fatal(err)
	}
	var mu sync.Mutex
	passed := 0
	var wg sync.WaitGroup
	for range 64 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if _, err := h.api.holdPhotoRoom(member, 100<<20); err == nil {
				mu.Lock()
				passed++
				mu.Unlock()
			}
		}()
	}
	wg.Wait()
	if passed != 10 {
		t.Fatalf("%d uploads of 100MB held against 1GB", passed)
	}
}
