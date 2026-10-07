package library

import (
	"path"
	"regexp"
	"strings"
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
