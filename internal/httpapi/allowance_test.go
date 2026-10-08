package httpapi

import (
	"fmt"
	"testing"
	"time"
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
