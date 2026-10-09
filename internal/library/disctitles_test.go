package library

import (
	"fmt"
	"testing"

	"github.com/GabrielHollberg/soundstorm/internal/media"
)

// A disc ripped by MakeMKV is every title named alike: the largest is the
// film, one nearly as large a second version, the rest its extras - and no two
// land on one name, where they all used to (the owner's report, 2026-10-09).
func TestADiscsTitlesAreNotAllTheFilm(t *testing.T) {
	dir := "The Glass Harbor/"
	paths := []string{dir + "The Glass Harbor_t00.mkv", dir + "The Glass Harbor_t12.mkv"}
	sizes := []int64{26_970_000_000, 27_110_000_000}
	for n := 1; n <= 30; n++ {
		if n == 12 {
			continue
		}
		paths = append(paths, fmt.Sprintf("%sThe Glass Harbor_t%02d.mkv", dir, n))
		sizes = append(sizes, 300_000_000)
	}
	paths = append(paths, dir+"The Glass Harbor_t03.en.srt")
	sizes = append(sizes, 40_000)

	l := newLibrary(t)
	placements, _ := l.PlanSized(paths, sizes, map[string]media.Kind{"The Glass Harbor": media.KindVideo})

	seen := map[string]string{}
	for _, p := range placements {
		if p.Dest == "" {
			t.Fatalf("%s: not placed (%+v)", p.Path, p)
		}
		if other, dup := seen[p.Dest]; dup {
			t.Fatalf("%s and %s both go to %s", other, p.Path, p.Dest)
		}
		seen[p.Dest] = p.Path
		// The server files the upload by the name it carries, tidied again:
		// that must change nothing, or plan and save disagree.
		if p.Upload != "" {
			if got := tidyFilm(p.Upload); got != p.Upload {
				t.Errorf("%s: the upload's name %q becomes %q when filed", p.Path, p.Upload, got)
			}
		}
	}
	want := map[string]string{
		"The Glass Harbor_t12.mkv":    "movies/The Glass Harbor/The Glass Harbor.mkv",
		"The Glass Harbor_t00.mkv":    "movies/The Glass Harbor/The Glass Harbor - t00.mkv",
		"The Glass Harbor_t01.mkv":    "movies/The Glass Harbor/extras/The Glass Harbor - t01.mkv",
		"The Glass Harbor_t03.en.srt": "movies/The Glass Harbor/extras/The Glass Harbor - t03.en.srt",
	}
	for _, p := range placements {
		if w, ok := want[p.Path[len(dir):]]; ok && p.Dest != w {
			t.Errorf("%s went to %s, want %s", p.Path, p.Dest, w)
		}
	}

	// One title alone is the film, as before.
	one, _ := l.PlanSized([]string{"The Quiet Meridian_t00.mkv"}, []int64{30_000_000_000}, nil)
	if one[0].Dest != "movies/The Quiet Meridian/The Quiet Meridian.mkv" || one[0].Upload != "" {
		t.Errorf("a single title: %+v", one[0])
	}
}
