package httpapi

import (
	"testing"

	"github.com/GabrielHollberg/soundstorm/internal/desktoprelease"
)

// A newer release is told by the release an install came from, else - for an
// install from before the installers wrote it - by when its build was made.
func TestANewerReleaseIsToldByItsSerialOrItsDate(t *testing.T) {
	m := &desktoprelease.Manifest{Serial: 2026101301, Commit: "c845f250e5333508efb6e498764488c315fab564", Created: "2026-10-13T20:00:00Z"}
	cases := []struct {
		name         string
		serial       int64
		commit, date string
		want         bool
	}{
		{"an older release installed", 2026101203, "", "", true},
		{"this release installed", 2026101301, "", "", false},
		{"a newer one than the latest (a test release)", 2026101399, "", "", false},
		{"no serial, built days before", 0, "aaaaaaa", "2026-10-09T10:00:00Z", true},
		{"no serial, built the same day", 0, "aaaaaaa", "2026-10-13T10:00:00Z", false},
		{"no serial, the very commit", 0, "c845f250e5333508efb6e498764488c315fab564", "2026-10-01T10:00:00Z", false},
		{"nothing known", 0, "", "", false},
	}
	for _, c := range cases {
		if got := newerThanThis(m, c.serial, c.commit, c.date); got != c.want {
			t.Errorf("%s: newer = %v, want %v", c.name, got, c.want)
		}
	}
}
