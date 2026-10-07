package library

import "testing"

// A ripper's names become ones Jellyfin recognises; a tidy name is left be.
func TestFilmNamesAreTidied(t *testing.T) {
	for in, want := range map[string]string{
		"The Quiet Meridian_t00.mkv":                                "The Quiet Meridian/The Quiet Meridian.mkv",
		"The Long Road North- The Second Crossing (EXT.) PT. 1_t01.mkv": "The Long Road North - The Second Crossing (EXT.)/The Long Road North - The Second Crossing (EXT.) - part1.mkv",
		"The Long Road North- The Second Crossing (EXT.) PT. 2_t01.mkv": "The Long Road North - The Second Crossing (EXT.)/The Long Road North - The Second Crossing (EXT.) - part2.mkv",
		"Dune (2021).mkv":             "Dune (2021)/Dune (2021).mkv",
		"Dune (2021)/Dune (2021).mkv": "Dune (2021)/Dune (2021).mkv",
		"Dune (2021)/Dune_t03.en.srt": "Dune (2021)/Dune.en.srt",
		"Alien CD2.avi":               "Alien/Alien - part2.avi",
		"Heat Disc 01.mkv":            "Heat/Heat - part1.mkv",
		"My Films/Up_t00.mp4":         "My Films/Up.mp4",
		"Apartment 12.mkv":            "Apartment 12/Apartment 12.mkv",
		"_t00.mkv":                    "_t00.mkv",
	} {
		if got := tidyFilm(in); got != want {
			t.Errorf("%q: got %q, want %q", in, got, want)
		}
	}
}
