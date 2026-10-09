package library

import (
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"

	"github.com/GabrielHollberg/soundstorm/internal/media"
)

// clip is a tiny MP4 that says it runs secs seconds (only its movie header).
func clip(secs int, pad byte) []byte {
	box := func(kind string, body []byte) []byte {
		b := make([]byte, 8, 8+len(body))
		binary.BigEndian.PutUint32(b, uint32(8+len(body)))
		copy(b[4:], kind)
		return append(b, body...)
	}
	mvhd := make([]byte, 100)
	binary.BigEndian.PutUint32(mvhd[12:], 1000)
	binary.BigEndian.PutUint32(mvhd[16:], uint32(secs*1000))
	return append(box("moov", box("mvhd", mvhd)), box("mdat", []byte{pad, pad, pad})...)
}

// A disc's titles named for what they are as they arrive: extras by their
// length, a second version by how it differs from the film, and subtitles
// following their title whichever came first.
func TestADiscsTitlesAreNamedForWhatTheyAre(t *testing.T) {
	l := newLibrary(t)
	shelf := l.PathFor(media.KindVideo)

	saved(t, l, media.KindVideo, "Film/Film.mp4", clip(8460, 1))

	// A subtitle before its extra; then the extra; then a second extra of the
	// same length.
	saved(t, l, media.KindVideo, "Film/extras/Film - t03.en.srt", []byte("1\n00:00:01,000 --> 00:00:02,000\nhi\n"))
	if got := saved(t, l, media.KindVideo, "Film/extras/Film - t03.mp4", clip(300, 2)); got != "movies/Film/extras/Film - Extra (5 min).mp4" {
		t.Errorf("extra filed as %q", got)
	}
	if _, err := os.Stat(filepath.Join(shelf, "Film", "extras", "Film - Extra (5 min).en.srt")); err != nil {
		t.Errorf("the subtitle that came first did not follow: %v", err)
	}
	if got := saved(t, l, media.KindVideo, "Film/extras/Film - t04.mp4", clip(310, 3)); got != "movies/Film/extras/Film - Extra 2 (5 min).mp4" {
		t.Errorf("second extra filed as %q", got)
	}

	// A second version beside the film, named by its length; its subtitle
	// arriving after it follows.
	if got := saved(t, l, media.KindVideo, "Film/Film - t12.mp4", clip(8640, 4)); got != "movies/Film/Film - 2h 24m.mp4" {
		t.Errorf("version filed as %q", got)
	}
	if got := saved(t, l, media.KindVideo, "Film/Film - t12.en.srt", []byte("1\n00:00:01,000 --> 00:00:02,000\nhi\n")); got != "movies/Film/Film - 2h 24m.en.srt" {
		t.Errorf("version's subtitle filed as %q", got)
	}

	// A title nothing can be read from keeps its number.
	if got := saved(t, l, media.KindVideo, "Film/extras/Film - t09.mp4", []byte("not a video")); got != "movies/Film/extras/Film - t09.mp4" {
		t.Errorf("unreadable title filed as %q", got)
	}
}
