package version

import "testing"

func TestTheBuildIsSaidOnlyWhenStamped(t *testing.T) {
	Commit, Date = "", ""
	if b := Current(); b.Commit != "" || b.Date != "" {
		t.Fatalf("an unstamped build said %+v", b)
	}
	Commit, Date = "665d6621f00dbeef665d6621f00dbeef665d6621", "2026-10-12T03:58:00-06:00"
	b := Current()
	if b.Commit != "665d662" || b.Date != "2026-10-12T09:58:00Z" {
		t.Fatalf("got %+v", b)
	}
	Commit, Date = "<script>", "yesterday"
	if b := Current(); b.Commit != "" || b.Date != "" {
		t.Fatalf("a bad stamp was shown: %+v", b)
	}
}
