package library

import (
	"path"
	"regexp"
	"strings"

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
	filmPart    = regexp.MustCompile(`(?i)[ _.-]*\b(?:pt|part|cd|dis[ck])[ _.]*(\d{1,2})$`)
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
	if m := filmPart.FindStringSubmatch(name); m != nil {
		part = " - part" + strings.TrimLeft(m[1], "0")
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
