package library

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/GabrielHollberg/soundstorm/internal/media"
)

// The owner's ripped disc of Avatar: four episodes, the four as one
// "play all", and a short extra - in MakeMKV's names, which say nothing.
var avatarDisc = []EpisodeFile{
	{Rel: "Harbor Lights/A1_t05.mkv", Size: 330_000_000, Seconds: 330},
	{Rel: "Harbor Lights/B1_t00.mkv", Size: 5_470_000_000, Seconds: 5526},
	{Rel: "Harbor Lights/C1_t01.mkv", Size: 1_420_000_000, Seconds: 1410},
	{Rel: "Harbor Lights/C2_t02.mkv", Size: 1_310_000_000, Seconds: 1332},
	{Rel: "Harbor Lights/C3_t03.mkv", Size: 1_370_000_000, Seconds: 1398},
	{Rel: "Harbor Lights/C4_t04.mkv", Size: 1_370_000_000, Seconds: 1386},
}

func TestADiscsEpisodesAreNumbered(t *testing.T) {
	const folder, show = "Harbor Lights", "Harbor Lights"
	for _, timed := range []bool{true, false} {
		files := append([]EpisodeFile(nil), avatarDisc...)
		if !timed {
			for i := range files {
				files[i].Seconds = 0 // before the bytes arrive: sizes only
			}
		}
		got := map[string]EpisodeRow{}
		for _, r := range SuggestEpisodes(folder, show, files, 0, 0) {
			got[strings.TrimPrefix(r.Rel, folder+"/")] = r
		}
		want := map[string]string{
			"C1_t01.mkv": folder + "/Season 01/" + show + " S01E01.mkv",
			"C2_t02.mkv": folder + "/Season 01/" + show + " S01E02.mkv",
			"C3_t03.mkv": folder + "/Season 01/" + show + " S01E03.mkv",
			"C4_t04.mkv": folder + "/Season 01/" + show + " S01E04.mkv",
			"A1_t05.mkv": folder + "/extras/A1_t05.mkv",
		}
		for name, target := range want {
			if got[name].Target != target {
				t.Errorf("timed %v: %s -> %q (%s), want %q", timed, name, got[name].Target, got[name].Role, target)
			}
		}
		if got["B1_t00.mkv"].Role != RolePlayAll {
			t.Errorf("timed %v: the play-all was %+v", timed, got["B1_t00.mkv"])
		}
	}

	// A second disc carries on from the first.
	more := []EpisodeFile{
		{Rel: folder + "/Season 01/" + show + " S01E04.mkv", Size: 1_370_000_000},
		{Rel: folder + "/Disc 2/D1_t01.mkv", Size: 1_400_000_000},
		{Rel: folder + "/Disc 2/D2_t02.mkv", Size: 1_380_000_000},
	}
	rows := SuggestEpisodes(folder, show, more, 0, 0)
	if rows[1].Episode != 5 || rows[2].Episode != 6 {
		t.Errorf("second disc numbered %+v", rows)
	}
}

// Applied, the files are where the numbering says, a subtitle with its
// episode, the play-all in the bin, and two episodes can swap places.
func TestEpisodesAreRenamedAsNumbered(t *testing.T) {
	l := newLibrary(t)
	shelf := l.PathFor(media.KindTV)
	const folder = "Show"
	write := func(rel string) {
		p := filepath.Join(shelf, filepath.FromSlash(rel))
		_ = os.MkdirAll(filepath.Dir(p), 0o777)
		if err := os.WriteFile(p, []byte(rel), 0o666); err != nil {
			t.Fatal(err)
		}
	}
	for _, f := range []string{"Show/a_t01.mkv", "Show/a_t01.en.srt", "Show/b_t02.mkv", "Show/all_t00.mkv"} {
		write(f)
	}
	rows := []EpisodeRow{
		{Rel: "Show/a_t01.mkv", Role: RoleEpisode, Season: 1, Episode: 2},
		{Rel: "Show/b_t02.mkv", Role: RoleEpisode, Season: 1, Episode: 1},
		{Rel: "Show/all_t00.mkv", Role: RolePlayAll},
	}
	moved, binned, err := l.ApplyEpisodes(folder, "Show", rows, "owner")
	if err != nil || binned != 1 {
		t.Fatalf("apply: moved %d binned %d: %v", moved, binned, err)
	}
	for rel, from := range map[string]string{
		"Show/Season 01/Show S01E02.mkv":    "Show/a_t01.mkv",
		"Show/Season 01/Show S01E02.en.srt": "Show/a_t01.en.srt",
		"Show/Season 01/Show S01E01.mkv":    "Show/b_t02.mkv",
	} {
		b, err := os.ReadFile(filepath.Join(shelf, filepath.FromSlash(rel)))
		if err != nil || string(b) != from {
			t.Errorf("%s holds %q (%v), want %s", rel, b, err, from)
		}
	}
	if _, err := os.Stat(filepath.Join(shelf, "Show", "all_t00.mkv")); err == nil {
		t.Error("the play-all is still there")
	}

	// Swapped back by hand: E01 and E02 trade places.
	swap := []EpisodeRow{
		{Rel: "Show/Season 01/Show S01E02.mkv", Role: RoleEpisode, Season: 1, Episode: 1},
		{Rel: "Show/Season 01/Show S01E01.mkv", Role: RoleEpisode, Season: 1, Episode: 2},
	}
	if _, _, err := l.ApplyEpisodes(folder, "Show", swap, "owner"); err != nil {
		t.Fatalf("swap: %v", err)
	}
	if b, _ := os.ReadFile(filepath.Join(shelf, "Show", "Season 01", "Show S01E01.mkv")); string(b) != "Show/a_t01.mkv" {
		t.Errorf("after the swap E01 holds %q", b)
	}
	// Two onto one name is refused, and nothing moves.
	clash := []EpisodeRow{
		{Rel: "Show/Season 01/Show S01E01.mkv", Role: RoleEpisode, Season: 1, Episode: 3},
		{Rel: "Show/Season 01/Show S01E02.mkv", Role: RoleEpisode, Season: 1, Episode: 3},
	}
	if _, _, err := l.ApplyEpisodes(folder, "Show", clash, "owner"); err == nil {
		t.Error("two episodes numbered alike were taken")
	}
	// A file outside the show is refused.
	if _, _, err := l.ApplyEpisodes(folder, "Show", []EpisodeRow{{Rel: "Other/x.mkv", Role: RoleEpisode, Season: 1, Episode: 1}}, "owner"); err == nil {
		t.Error("a file outside the show was taken")
	}
}

// Planning a ripped disc's upload numbers it before anything is sent.
func TestAnUploadedDiscIsNumbered(t *testing.T) {
	l := newLibrary(t)
	var paths []string
	var sizes []int64
	for _, f := range avatarDisc {
		paths = append(paths, f.Rel)
		sizes = append(sizes, f.Size)
	}
	paths = append(paths, "Harbor Lights/C2_t02.en.srt")
	sizes = append(sizes, 50_000)
	out, _ := l.PlanSized(paths, sizes, map[string]media.Kind{"Harbor Lights": media.KindTV})
	got := map[string]Placement{}
	for _, p := range out {
		got[p.Path] = p
	}
	if p := got["Harbor Lights/C1_t01.mkv"]; p.Upload != "Harbor Lights/Season 01/Harbor Lights S01E01.mkv" {
		t.Errorf("C1 planned %+v", p)
	}
	if p := got["Harbor Lights/C2_t02.en.srt"]; p.Upload != "Harbor Lights/Season 01/Harbor Lights S01E02.en.srt" {
		t.Errorf("C2's subtitle planned %+v", p)
	}
	if p := got["Harbor Lights/B1_t00.mkv"]; !p.Skipped {
		t.Errorf("the play-all planned %+v", p)
	}
	if p := got["Harbor Lights/A1_t05.mkv"]; p.Upload != "Harbor Lights/extras/A1_t05.mkv" {
		t.Errorf("the extra planned %+v", p)
	}
}
