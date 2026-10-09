package library

import (
	"fmt"
	"math"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"
	"sync"

	"github.com/GabrielHollberg/soundstorm/internal/media"
)

// Films keep the names they arrive with, but not a disc ripper's leftovers
// (the owner's asking, 2026-10-07). Jellyfin finds a film's poster and details
// by its name, and MakeMKV saves "The Quiet Meridian_t00.mkv" or "... PT.
// 1_t01.mkv": half the owner's films went unrecognised, showing a frame of the
// video for a cover. So, as a film is filed:
//
//   - a ripper's title number (_t00, _t14) is taken off;
//   - "PT. 1", "Part 2", "CD1", "Disc 2" at the end become Jellyfin's own
//     " - part1", so the halves of one film show as one;
//   - "Rings- The" (a colon a ripper turned into a dash) gets its space back;
//   - a loose film goes in a folder of its own name, as Jellyfin asks, which
//     is also what lets two parts or two versions of it show as one film.
//
// A film dropped inside a folder keeps the folder. Its companions - a
// subtitle "_t00.en.srt" - are named the same way, so they stay beside it.
// Television is left exactly as it came: its seasons and episode numbers are
// what Jellyfin reads there.

var (
	rippedTitle = regexp.MustCompile(`(?i)[ _.-]*_t\d{2,3}$`)
	filmPart    = regexp.MustCompile(`(?i)[ _.-]*\b(pt|part|cd|dis[ck])[ _.]*(\d{1,2})$`)
	lostColon   = regexp.MustCompile(`(\S)- `)
	manySpaces  = regexp.MustCompile(`\s{2,}`)
	// What may follow a film's name in a companion's: a language, "forced".
	companionTail = regexp.MustCompile(`(?i)(\.(?:[a-z]{2,3}|forced|sdh|default))+$`)
)

// A disc's other titles are not the film (the owner's report, 2026-10-09):
// MakeMKV names every title on a disc the same way - "The Meridian
// Supremacy_t00.mkv" to "_t30" - and taking the number off each made them all
// "The Glass Harbor.mkv". The first to arrive took the name, an extra of
// 292MB, and the film and the rest were refused as already there. So where a
// drop has several titles of one film, the plan sees them together
// (discTitles, from their sizes): the largest is the film and keeps the tidy
// name; one nearly as large (half its size or more - another cut, another
// angle) is a second version beside it, "Name - t12.mkv", which Jellyfin shows
// as one film with a version to choose; the rest are its extras,
// "Name/extras/Name - t01.mkv", which Jellyfin shows under the film. Each
// keeps its title number, so no two meet. Without sizes (an older page) every
// title keeps its number beside the film, none taken for it.
var titleNumber = regexp.MustCompile(`(?i)_t(\d{2,3})$`)

func discTitles(out []Placement, sizes []int64) {
	type title struct {
		i     int
		num   string
		size  int64
		video bool
		tail  string
	}
	groups := map[string][]title{}
	var keys []string
	for i, p := range out {
		if p.Kind != media.KindVideo || p.Dest == "" {
			continue
		}
		rel, err := cleanRelPath(p.Path)
		if err != nil {
			continue
		}
		base := path.Base(rel)
		ext := path.Ext(base)
		stem := strings.TrimSuffix(base, ext)
		tail := companionTail.FindString(stem)
		m := titleNumber.FindStringSubmatch(strings.TrimSuffix(stem, tail))
		if m == nil {
			continue
		}
		destStem := strings.TrimSuffix(strings.TrimSuffix(path.Base(p.Dest), path.Ext(p.Dest)), tail)
		key := path.Dir(p.Dest) + "\x00" + destStem
		var size int64
		if i < len(sizes) {
			size = sizes[i]
		}
		if _, seen := groups[key]; !seen {
			keys = append(keys, key)
		}
		groups[key] = append(groups[key], title{i, m[1], size, !companionExtensions[strings.ToLower(ext)], tail})
	}
	for _, key := range keys {
		titles := groups[key]
		var videos int
		var largest int64
		main := ""
		for _, t := range titles {
			if t.video {
				videos++
				if t.size > largest {
					largest, main = t.size, t.num
				}
			}
		}
		if videos < 2 {
			continue
		}
		// Where each title number goes: "" the film itself, "version" beside
		// it, "extra" in its extras folder.
		role := map[string]string{}
		for _, t := range titles {
			if !t.video {
				continue
			}
			switch {
			case t.num == main:
				role[t.num] = ""
			case largest > 0 && t.size*2 < largest:
				role[t.num] = "extra"
			default:
				role[t.num] = "version"
			}
		}
		for _, t := range titles {
			r, known := role[t.num]
			if !known || r == "" {
				continue // the film, or a companion of no title here
			}
			p := &out[t.i]
			dir, base := path.Split(p.Dest)
			ext := path.Ext(base)
			name := strings.TrimSuffix(strings.TrimSuffix(base, ext), t.tail) + " - t" + t.num + t.tail + ext
			if r == "extra" {
				dir += "extras/"
			}
			p.Dest = dir + name
			// The upload names where the plan put it: the server, seeing one
			// file at a time, cannot tell a film from its extras.
			p.Upload = strings.TrimPrefix(p.Dest, folderName(media.KindVideo)+"/")
		}
	}
}

// titleBeside is where a ripper's numbered title goes when its film's tidy
// name (rel, within the films shelf at folder) is already another file's:
// extras dropped after their film, in a drop of their own, which the plan
// cannot see together with it. Much smaller than what is there, it is an
// extra; as large or larger, a second version; exactly its size, or of a size
// not known, it is left alone, for the copy check to judge. dropped is the
// name it arrived with, size its size. ok false leaves rel as it was.
func titleBeside(folder, rel, dropped string, size int64) (string, bool) {
	d, err := cleanRelPath(dropped)
	if err != nil {
		return rel, false
	}
	base := path.Base(d)
	ext := path.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	tail := companionTail.FindString(stem)
	m := titleNumber.FindStringSubmatch(strings.TrimSuffix(stem, tail))
	if m == nil {
		return rel, false
	}
	there, err := os.Lstat(filepath.Join(folder, filepath.FromSlash(rel)))
	if err != nil || !there.Mode().IsRegular() {
		return rel, false
	}
	video := !companionExtensions[strings.ToLower(ext)]
	if video && (size <= 0 || size == there.Size()) {
		return rel, false
	}
	dir, file := path.Split(rel)
	fext := path.Ext(file)
	name := strings.TrimSuffix(strings.TrimSuffix(file, fext), tail) + " - t" + m[1] + tail + fext
	if !video || size*2 < there.Size() {
		dir += "extras/"
	}
	out := dir + name
	if _, err := os.Lstat(filepath.Join(folder, filepath.FromSlash(out))); err == nil {
		return rel, false
	}
	return out, true
}

// A disc's other titles are named for what they are once they arrive (the
// owner's asking, 2026-10-09): the plan, knowing only sizes, gives each its
// ripper's number - "Name - t12.mkv" beside the film, "extras/Name -
// t01.mkv" - and as the bytes land the number is swapped for something a
// person can tell apart. A second version is named by what differs from the
// film: its picture size when that differs, else its length ("Name - 2h
// 21m.mkv", the label Jellyfin shows for the version); an extra by its length
// ("Name - Extra (12 min).mkv", a number added when two match). A subtitle
// that came with a title follows it: one already there is renamed with it,
// one arriving after is given the new name (titleRenames, for as long as the
// server runs - a drop's files come together). Unreadable, the number stays.
var (
	numberedTitle = regexp.MustCompile(`^(.*) - t(\d{2,3})$`)
	titleRenames  sync.Map // folder + "\x00" + dir + old core -> new core
)

func labelTitle(folder, rel, staged string) string {
	dir, file := path.Split(rel)
	ext := path.Ext(file)
	stem := strings.TrimSuffix(file, ext)
	tail := companionTail.FindString(stem)
	core := strings.TrimSuffix(stem, tail)
	m := numberedTitle.FindStringSubmatch(core)
	if m == nil {
		return rel
	}
	key := folder + "\x00" + dir + core
	if companionExtensions[strings.ToLower(ext)] {
		if v, ok := titleRenames.Load(key); ok {
			return dir + v.(string) + tail + ext
		}
		return rel
	}
	base := m[1]
	t := TraitsOf(media.KindVideo, staged)
	var label string
	if path.Base(strings.TrimSuffix(dir, "/")) == "extras" {
		if t.Seconds <= 0 {
			return rel
		}
		label = "Extra (" + minutes(t.Seconds) + ")"
	} else {
		have := TraitsOf(media.KindVideo, filepath.Join(folder, filepath.FromSlash(dir+base+ext)))
		switch p := resolution(t); {
		case p != "" && p != resolution(have):
			label = p
		case t.Seconds > 0:
			label = length(t.Seconds)
		default:
			return rel
		}
	}
	newCore := ""
	for n := 1; n < 100; n++ {
		l := label
		if n > 1 {
			if strings.HasPrefix(label, "Extra (") {
				l = fmt.Sprintf("Extra %d (%s", n, strings.TrimPrefix(label, "Extra ("))
			} else {
				l = fmt.Sprintf("%s %d", label, n)
			}
		}
		c := base + " - " + labelName(l)
		if _, err := os.Lstat(filepath.Join(folder, filepath.FromSlash(dir+c+ext))); err != nil {
			newCore = c
			break
		}
	}
	if newCore == "" {
		return rel
	}
	titleRenames.Store(key, newCore)
	// Its subtitles that arrived first follow it.
	here := filepath.Join(folder, filepath.FromSlash(dir))
	if entries, err := os.ReadDir(here); err == nil {
		for _, e := range entries {
			name := e.Name()
			if !e.Type().IsRegular() || !strings.HasPrefix(name, core+".") ||
				!companionExtensions[strings.ToLower(path.Ext(name))] {
				continue
			}
			to := newCore + strings.TrimPrefix(name, core)
			if _, err := os.Lstat(filepath.Join(here, to)); err == nil {
				continue
			}
			_ = os.Rename(filepath.Join(here, name), filepath.Join(here, to))
		}
	}
	return dir + newCore + tail + ext
}

// minutes is an extra's length as people say it: "12 min", "40 sec".
func minutes(s float64) string {
	if s < 60 {
		return fmt.Sprintf("%d sec", int(math.Round(s)))
	}
	return fmt.Sprintf("%d min", int(math.Round(s/60)))
}

// tidyFilm is a film's place on its shelf (rel within it) with the ripper's
// leftovers taken out.
func tidyFilm(rel string) string {
	dir, base := path.Split(rel)
	ext := path.Ext(base)
	stem := strings.TrimSuffix(base, ext)
	tail := companionTail.FindString(stem)
	stem = strings.TrimSuffix(stem, tail)

	name := rippedTitle.ReplaceAllString(stem, "")
	part := ""
	// "Part 1" is often a film's own title - two films called Part 1 and
	// Part 2 were filed as two halves of one film (a review, 2026-10-09),
	// ripped from their discs or not. So only the ripper's forms (PT. 1,
	// CD1, Disc 2) stack; a plain "Part N" stays in the name. A film really
	// in two halves named so shows as two, which Find the right film mends,
	// where a sequel hidden inside its first film could not be found at all.
	if m := filmPart.FindStringSubmatch(name); m != nil && !strings.EqualFold(m[1], "part") {
		part = " - part" + strings.TrimLeft(m[2], "0")
		if part == " - part" {
			part = " - part0"
		}
		name = filmPart.ReplaceAllString(name, "")
	}
	name = lostColon.ReplaceAllString(name, "$1 - ")
	name = strings.Trim(manySpaces.ReplaceAllString(name, " "), " ._-")
	if name == "" {
		return rel
	}
	tidied := name + part + tail + ext
	if dir == "" {
		// Loose on the shelf: into a folder of its own.
		dir = name + "/"
	}
	out, err := cleanRelPath(dir + tidied)
	if err != nil {
		return rel
	}
	return out
}
