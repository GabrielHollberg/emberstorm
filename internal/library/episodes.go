package library

import (
	"errors"
	"fmt"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/GabrielHollberg/soundstorm/internal/media"
)

// Episodes named and put in order (the owner's asking, 2026-10-09: a ripped
// disc of Avatar came in as "A1_t05", "B1_t00", "C1_t01"... and Jellyfin,
// which matches an episode by "S01E01" in its name, could tell nothing: no
// names, no stills). A show's files are looked at together:
//
//   - a file already named with its episode ("S01E03", "1x03") keeps it;
//   - a "play all" title - one as long as several others put together, which
//     a disc carries beside its episodes - is not kept;
//   - a file much shorter than the rest is an extra, in the show's "extras"
//     folder, where Jellyfin shows it under the show;
//   - the rest are episodes, in the order they were ripped (the ripper's
//     title number), numbered on from the last episode the show already has
//     (Season 1, Episode 1 for a new show), and named as Jellyfin reads them:
//     "Show/Season 01/Show S01E01.mkv".
//
// Lengths are used when known (the show already on the shelf, from Jellyfin);
// before the bytes arrive only sizes are, which on one disc follow the length
// closely. Whatever this decides can be put right by hand in a show's menu,
// Number the episodes, which renames the files as asked (ApplyEpisodes).

// EpisodeFile is one file of a show: relative to the TV shelf, its size, and
// its length in seconds where known.
type EpisodeFile struct {
	Rel     string
	Size    int64
	Seconds float64
}

// What becomes of a show's file.
const (
	RoleEpisode = "episode"
	RolePlayAll = "playall" // the episodes joined; not kept
	RoleExtra   = "extra"
	RoleDrop    = "drop" // not kept
)

// EpisodeRow is a show's file and what becomes of it.
type EpisodeRow struct {
	Rel     string  `json:"path"`
	Size    int64   `json:"size"`
	Seconds float64 `json:"seconds,omitempty"`
	Role    string  `json:"role"`
	Season  int     `json:"season,omitempty"`
	Episode int     `json:"episode,omitempty"`
	// Target is where it goes, relative to the TV shelf; "" for a file not
	// kept.
	Target string `json:"target,omitempty"`
}

var (
	episodeMark = regexp.MustCompile(`(?i)(?:\bs(\d{1,2})[ ._-]*e(\d{1,3})\b|\b(\d{1,2})x(\d{2,3})\b)`)
	seasonDir   = regexp.MustCompile(`(?i)^(?:season|series|staffel|saison)[ ._-]*(\d{1,2})$`)
)

// HasEpisodeNumber reports whether a name says which episode it is.
func HasEpisodeNumber(name string) bool { return episodeMark.MatchString(name) }

// episodeOf is the season and episode a name says, or 0, 0.
func episodeOf(name string) (int, int) {
	m := episodeMark.FindStringSubmatch(name)
	if m == nil {
		return 0, 0
	}
	if m[1] != "" {
		s, _ := strconv.Atoi(m[1])
		e, _ := strconv.Atoi(m[2])
		return s, e
	}
	s, _ := strconv.Atoi(m[3])
	e, _ := strconv.Atoi(m[4])
	return s, e
}

// isVideo is whether a file is a video the TV shelf keeps, not a companion.
func isVideo(rel string) bool {
	return mediaExtensions[media.KindTV][strings.ToLower(path.Ext(rel))]
}

// SuggestEpisodes orders and numbers a show's files (see above). show is its
// name, as its files are to be named; folder is its folder on the TV shelf.
// startSeason and startEpisode set where the first new episode is numbered,
// 0 for on from the last the show has.
func SuggestEpisodes(folder, show string, files []EpisodeFile, startSeason, startEpisode int) []EpisodeRow {
	var rows []EpisodeRow
	var fresh []int
	maxSeason, maxEpisode := 0, 0
	for _, f := range files {
		if !isVideo(f.Rel) {
			continue
		}
		r := EpisodeRow{Rel: f.Rel, Size: f.Size, Seconds: f.Seconds}
		if inExtras(folder, f.Rel) {
			r.Role = RoleExtra
		} else if s, e := episodeOf(path.Base(f.Rel)); e > 0 {
			r.Role, r.Season, r.Episode = RoleEpisode, max(s, 1), e
			if r.Season > maxSeason || (r.Season == maxSeason && r.Episode > maxEpisode) {
				maxSeason, maxEpisode = r.Season, r.Episode
			}
		} else {
			fresh = append(fresh, len(rows))
		}
		rows = append(rows, r)
	}

	// Lengths if every new file has one, else sizes.
	measure := func(r EpisodeRow) float64 { return float64(r.Size) }
	allTimed := len(fresh) > 0
	for _, i := range fresh {
		if rows[i].Seconds <= 0 {
			allTimed = false
		}
	}
	if allTimed {
		measure = func(r EpisodeRow) float64 { return r.Seconds }
	}

	// Extras: much shorter than the rest (with enough of them to tell).
	candidates := append([]int(nil), fresh...)
	if len(candidates) >= 3 {
		ms := make([]float64, 0, len(candidates))
		for _, i := range candidates {
			ms = append(ms, measure(rows[i]))
		}
		sort.Float64s(ms)
		median := ms[len(ms)/2]
		var kept []int
		for _, i := range candidates {
			if measure(rows[i]) < 0.4*median {
				rows[i].Role = RoleExtra
			} else {
				kept = append(kept, i)
			}
		}
		candidates = kept
	}

	// A play-all: the longest, as long as all the others together.
	if len(candidates) >= 3 {
		longest := candidates[0]
		for _, i := range candidates {
			if measure(rows[i]) > measure(rows[longest]) {
				longest = i
			}
		}
		// Its episodes: the others new, and those already numbered beside it
		// (the same disc's, sorted on an earlier go).
		var sum float64
		for _, i := range candidates {
			if i != longest {
				sum += measure(rows[i])
			}
		}
		for _, r := range rows {
			if r.Role == RoleEpisode && path.Dir(r.Rel) == path.Dir(rows[longest].Rel) {
				sum += measure(r)
			}
		}
		if l := measure(rows[longest]); sum > 0 && l > sum*0.92 && l < sum*1.08 {
			rows[longest].Role = RolePlayAll
			var kept []int
			for _, i := range candidates {
				if i != longest {
					kept = append(kept, i)
				}
			}
			candidates = kept
		}
	}

	// The episodes, in the order they were ripped, numbered on.
	sort.SliceStable(candidates, func(a, b int) bool {
		return ripOrderLess(rows[candidates[a]].Rel, rows[candidates[b]].Rel)
	})
	season, episode := startSeason, startEpisode
	if season <= 0 {
		season = max(maxSeason, 1)
		if startEpisode <= 0 {
			episode = 1
			if maxSeason == season {
				episode = maxEpisode + 1
			}
		}
	}
	if episode <= 0 {
		episode = 1
	}
	for _, i := range candidates {
		rows[i].Role, rows[i].Season, rows[i].Episode = RoleEpisode, season, episode
		episode++
	}
	for i := range rows {
		rows[i].Target = EpisodeTarget(folder, show, rows[i])
	}
	return rows
}

// inExtras is whether a file is already in the show's extras folder.
func inExtras(folder, rel string) bool {
	return strings.EqualFold(path.Dir(rel), folder+"/extras")
}

// ripTitle is a ripper's title number ("_t04" at the end), or -1.
func ripTitle(rel string) int {
	stem := strings.TrimSuffix(path.Base(rel), path.Ext(rel))
	if m := titleNumber.FindStringSubmatch(stem); m != nil {
		n, _ := strconv.Atoi(m[1])
		return n
	}
	return -1
}

// ripOrderLess orders a disc's files as they were ripped: by the folder they
// are in (Disc 1 before Disc 2), then the ripper's title number, then the
// name, numbers compared as numbers.
func ripOrderLess(a, b string) bool {
	if da, db := path.Dir(a), path.Dir(b); da != db {
		return naturalLess(da, db)
	}
	if ta, tb := ripTitle(a), ripTitle(b); ta >= 0 && tb >= 0 && ta != tb {
		return ta < tb
	}
	return naturalLess(path.Base(a), path.Base(b))
}

var digits = regexp.MustCompile(`\d+|\D+`)

// naturalLess compares names with runs of digits as numbers: "Disc 2" before
// "Disc 10".
func naturalLess(a, b string) bool {
	pa, pb := digits.FindAllString(strings.ToLower(a), -1), digits.FindAllString(strings.ToLower(b), -1)
	for i := 0; i < len(pa) && i < len(pb); i++ {
		if pa[i] == pb[i] {
			continue
		}
		na, ea := strconv.Atoi(pa[i])
		nb, eb := strconv.Atoi(pb[i])
		if ea == nil && eb == nil && na != nb {
			return na < nb
		}
		return pa[i] < pb[i]
	}
	return len(pa) < len(pb)
}

// EpisodeTarget is where a row's file goes on the TV shelf: an episode as
// "Show/Season 01/Show S01E01.mkv", an extra in "Show/extras/", and "" for a
// file not kept.
func EpisodeTarget(folder, show string, r EpisodeRow) string {
	ext := strings.ToLower(path.Ext(r.Rel))
	switch r.Role {
	case RoleEpisode:
		if r.Season < 0 || r.Season > 99 || r.Episode < 1 || r.Episode > 999 {
			return ""
		}
		out, err := cleanRelPath(fmt.Sprintf("%s/Season %02d/%s S%02dE%02d%s", folder, r.Season, show, r.Season, r.Episode, ext))
		if err != nil {
			return ""
		}
		return out
	case RoleExtra:
		out, err := cleanRelPath(folder + "/extras/" + path.Base(r.Rel))
		if err != nil {
			return ""
		}
		return out
	}
	return ""
}

// ErrEpisodeTaken refuses numbering two files the same, or onto a file that
// is not one of the show's being numbered.
var ErrEpisodeTaken = errors.New("two files would have the same name")

// ShowFiles lists the videos and their companions in a show's folder on the
// TV shelf, relative to it, with their sizes.
func (l *Library) ShowFiles(folder string) ([]EpisodeFile, error) {
	shelf := l.PathFor(media.KindTV)
	if shelf == "" {
		return nil, fmt.Errorf("there is no TV library")
	}
	folder, err := cleanFolder(folder)
	if err != nil {
		return nil, err
	}
	root := filepath.Join(shelf, filepath.FromSlash(folder))
	if !within(shelf, root) {
		return nil, fmt.Errorf("that folder is not on the TV shelf")
	}
	var out []EpisodeFile
	err = filepath.WalkDir(root, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if d.IsDir() {
			if strings.HasPrefix(d.Name(), ".") && p != root {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() || !isVideo(d.Name()) {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		rel, err := filepath.Rel(shelf, p)
		if err != nil {
			return nil
		}
		out = append(out, EpisodeFile{Rel: filepath.ToSlash(rel), Size: info.Size()})
		if len(out) > 2000 {
			return filepath.SkipAll
		}
		return nil
	})
	return out, err
}

// ApplyEpisodes renames a show's files as the rows say (their targets worked
// out again here from each row's role and numbers, never taken as given):
// episodes to "Season NN/Show SNNENN", extras to "extras/", and play-alls and
// files not kept to the bin. A file's companions - subtitles named after it -
// go with it. Every file must be in the show's folder; no two may land on one
// name, nor on a file that is not one of these. Files are first moved aside
// to names of their own, then to their places, so two episodes can swap.
func (l *Library) ApplyEpisodes(folder, show string, rows []EpisodeRow, by string) (moved, binned int, err error) {
	shelf := l.PathFor(media.KindTV)
	if shelf == "" {
		return 0, 0, fmt.Errorf("there is no TV library")
	}
	if folder, err = cleanFolder(folder); err != nil {
		return 0, 0, err
	}
	type move struct{ from, to string } // relative to the shelf
	var moves []move
	var drops []string
	targets := map[string]bool{}
	sources := map[string]bool{}
	for _, r := range rows {
		rel, err := cleanRelPath(r.Rel)
		if err != nil || !strings.HasPrefix(rel, folder+"/") || !isVideo(rel) {
			return 0, 0, fmt.Errorf("%s is not one of this show's files", path.Base(r.Rel))
		}
		if fi, err := os.Lstat(filepath.Join(shelf, filepath.FromSlash(rel))); err != nil || !fi.Mode().IsRegular() {
			return 0, 0, fmt.Errorf("%s is not there any more", path.Base(rel))
		}
		if sources[rel] {
			return 0, 0, fmt.Errorf("%s is listed twice", path.Base(rel))
		}
		sources[rel] = true
		switch r.Role {
		case RolePlayAll, RoleDrop:
			drops = append(drops, rel)
			continue
		case RoleEpisode, RoleExtra:
		default:
			return 0, 0, fmt.Errorf("what should become of %s?", path.Base(rel))
		}
		r.Rel = rel
		to := EpisodeTarget(folder, show, r)
		if to == "" {
			return 0, 0, fmt.Errorf("%s needs a season and an episode number", path.Base(rel))
		}
		if targets[strings.ToLower(to)] {
			return 0, 0, ErrEpisodeTaken
		}
		targets[strings.ToLower(to)] = true
		if to != rel {
			moves = append(moves, move{rel, to})
		}
		// Its companions: same folder, named after it ("x.en.srt").
		stem := strings.TrimSuffix(rel, path.Ext(rel))
		toStem := strings.TrimSuffix(to, path.Ext(to))
		entries, _ := os.ReadDir(filepath.Join(shelf, filepath.FromSlash(path.Dir(rel))))
		for _, e := range entries {
			c := path.Dir(rel) + "/" + e.Name()
			if e.IsDir() || !companionExtensions[strings.ToLower(path.Ext(c))] || !strings.HasPrefix(c, stem+".") {
				continue
			}
			ct := toStem + strings.TrimPrefix(c, stem)
			if targets[strings.ToLower(ct)] {
				return 0, 0, ErrEpisodeTaken
			}
			targets[strings.ToLower(ct)] = true
			if ct != c {
				moves = append(moves, move{c, ct})
				sources[c] = true
			}
		}
	}
	// Nothing lands on a file that is not one of these.
	for _, m := range moves {
		if _, err := os.Lstat(filepath.Join(shelf, filepath.FromSlash(m.to))); err == nil && !sources[m.to] {
			return 0, 0, fmt.Errorf("%s is already there: %w", path.Base(m.to), ErrEpisodeTaken)
		}
	}

	// Not kept: to the bin first, where they can be put back.
	if len(drops) > 0 {
		var paths []string
		for _, d := range drops {
			paths = append(paths, folderName(media.KindTV)+"/"+d)
		}
		if _, err := l.MoveToBin([]BinItem{{Title: show, Kind: media.KindTV, Paths: paths}}, by); err != nil {
			return 0, 0, fmt.Errorf("put the play-alls in the bin: %w", err)
		}
		binned = len(drops)
	}

	// Aside, then into place.
	type aside struct{ from, tmp, to string }
	var asides []aside
	for i, m := range moves {
		from := filepath.Join(shelf, filepath.FromSlash(m.from))
		tmp := filepath.Join(filepath.Dir(from), fmt.Sprintf(".renumber-%d-%s", i, filepath.Base(from)))
		if err := os.Rename(from, tmp); err != nil {
			for _, a := range asides { // put back what moved aside
				_ = os.Rename(a.tmp, a.from)
			}
			return 0, binned, fmt.Errorf("move %s: %w", filepath.Base(from), err)
		}
		asides = append(asides, aside{from, tmp, m.to})
	}
	for _, a := range asides {
		dest := filepath.Join(shelf, filepath.FromSlash(a.to))
		if !within(shelf, dest) {
			return moved, binned, fmt.Errorf("that path does not stay inside the library")
		}
		if err := ensureDir(filepath.Dir(dest)); err != nil {
			return moved, binned, err
		}
		if err := MoveNoClobber(a.tmp, dest); err != nil {
			return moved, binned, fmt.Errorf("put %s in place: %w", filepath.Base(dest), err)
		}
		moved++
	}
	// Folders left empty go, up to (never including) the show's own.
	showDir := filepath.Join(shelf, filepath.FromSlash(folder))
	for _, m := range moves {
		dir := filepath.Dir(filepath.Join(shelf, filepath.FromSlash(m.from)))
		for dir != showDir && within(showDir, dir) {
			if os.Remove(dir) != nil {
				break
			}
			dir = filepath.Dir(dir)
		}
	}
	l.Invalidate()
	return moved, binned, nil
}

// ShowName is the name a show's files are given, from its folder.
func ShowName(folder string) string {
	name := path.Base(folder)
	if seasonDir.MatchString(name) {
		name = path.Base(path.Dir(folder))
	}
	return name
}

// numberDrop numbers a TV drop whose videos say nothing of which episode
// they are - a ripped disc - in the plan, before anything is sent (see
// above): each show folder's videos are ordered and numbered on from the
// episodes the show already has, extras go to its extras folder, a play-all
// is left out, and subtitles follow their video. A drop where any video is
// numbered is left as it is: its names already say.
func (l *Library) numberDrop(out []Placement, sizes []int64) {
	prefix := folderName(media.KindTV) + "/"
	shows := map[string][]int{}
	var order []string
	for i, p := range out {
		if p.Kind != media.KindTV || p.Dest == "" || p.Upload != "" {
			continue
		}
		rel := strings.TrimPrefix(p.Dest, prefix)
		slash := strings.Index(rel, "/")
		if slash <= 0 {
			continue // a loose file: no show folder to name it after
		}
		show := rel[:slash]
		if _, ok := shows[show]; !ok {
			order = append(order, show)
		}
		shows[show] = append(shows[show], i)
	}
	for _, folder := range order {
		members := shows[folder]
		var files []EpisodeFile
		numbered := false
		for _, i := range members {
			rel := strings.TrimPrefix(out[i].Dest, prefix)
			if !isVideo(rel) {
				continue
			}
			if HasEpisodeNumber(path.Base(rel)) || seasonDir.MatchString(path.Base(path.Dir(rel))) {
				numbered = true
				break
			}
			var size int64
			if i < len(sizes) {
				size = sizes[i]
			}
			files = append(files, EpisodeFile{Rel: rel, Size: size})
		}
		if numbered || len(files) == 0 {
			continue
		}
		// On from the episodes the show already has on the shelf.
		var known []EpisodeFile
		if have, err := l.ShowFiles(folder); err == nil {
			for _, h := range have {
				if HasEpisodeNumber(path.Base(h.Rel)) {
					known = append(known, h)
				}
			}
		}
		show := ShowName(folder)
		rows := SuggestEpisodes(folder, show, append(known, files...), 0, 0)
		byRel := map[string]EpisodeRow{}
		for _, r := range rows {
			byRel[r.Rel] = r
		}
		// Each video's new stem, for its companions.
		newStem := map[string]string{}
		for _, i := range members {
			rel := strings.TrimPrefix(out[i].Dest, prefix)
			r, ok := byRel[rel]
			if !ok {
				continue
			}
			p := &out[i]
			switch {
			case r.Role == RolePlayAll:
				p.Skipped, p.Reason, p.Dest = true, "all the episodes in one file, which the episodes themselves already are", ""
				newStem[strings.TrimSuffix(rel, path.Ext(rel))] = ""
			case r.Target != "" && r.Target != rel:
				p.Dest, p.Upload = prefix+r.Target, r.Target
				newStem[strings.TrimSuffix(rel, path.Ext(rel))] = strings.TrimSuffix(r.Target, path.Ext(r.Target))
			}
		}
		for _, i := range members {
			p := &out[i]
			if p.Dest == "" {
				continue
			}
			rel := strings.TrimPrefix(p.Dest, prefix)
			if isVideo(rel) {
				continue
			}
			for stem, to := range newStem {
				if !strings.HasPrefix(rel, stem+".") {
					continue
				}
				if to == "" {
					p.Skipped, p.Reason, p.Dest = true, "it goes with a file that is not being added", ""
				} else {
					p.Upload = to + strings.TrimPrefix(rel, stem)
					p.Dest = prefix + p.Upload
				}
				break
			}
		}
	}
}

// cleanFolder is a show's folder on the TV shelf, checked as any path is:
// relative, no dot segments, nothing hidden.
func cleanFolder(folder string) (string, error) {
	folder = strings.Trim(strings.ReplaceAll(folder, "\\", "/"), "/")
	if folder == "" {
		return "", fmt.Errorf("which show?")
	}
	for _, seg := range strings.Split(folder, "/") {
		if seg == "" || seg == "." || seg == ".." || strings.HasPrefix(seg, ".") {
			return "", fmt.Errorf("that is not a show's folder")
		}
	}
	return folder, nil
}
