package photoimport

import (
	"bytes"
	"strings"
	"testing"
	"time"
)

// Fuzzing the photo date readers: go test -fuzz=FuzzReadTaken ./internal/photoimport.
// A photo, a download's sidecars and its file names are anybody's.

// A tiny JPEG with an EXIF DateTimeOriginal, little-endian.
var seedExif = func() []byte {
	tiff := []byte("II*\x00\x08\x00\x00\x00" + // header, IFD0 at 8
		"\x01\x00" + // one entry
		"\x69\x87\x04\x00\x01\x00\x00\x00\x1a\x00\x00\x00" + // ExifIFD at 26
		"\x00\x00\x00\x00" + // no next IFD
		"\x01\x00" + // Exif IFD: one entry
		"\x03\x90\x02\x00\x14\x00\x00\x00\x2c\x00\x00\x00" + // DateTimeOriginal at 44
		"\x00\x00\x00\x00" +
		"2019:12:25 09:00:00\x00")
	app1 := append([]byte("Exif\x00\x00"), tiff...)
	n := len(app1) + 2
	return append(append([]byte{0xFF, 0xD8, 0xFF, 0xE1, byte(n >> 8), byte(n)}, app1...), 0xFF, 0xD9)
}()

func FuzzReadTaken(f *testing.F) {
	f.Add(seedExif)
	f.Add([]byte("\x00\x00\x00\x18ftypheic\x00\x00\x00\x00mif1heic\x00\x00\x00\x08meta"))
	f.Fuzz(func(t *testing.T, data []byte) {
		withinTime(t, 3*time.Second, func() {
			head := data[:min(len(data), 512<<10)]
			_, _ = ReadTaken(bytes.NewReader(data), int64(len(data)), head)
			_, _ = ExifTaken(head)
			_ = ExifCamera(head)
			_ = ExifHasPlace(head)
		})
	})
}

func FuzzTakeoutJSON(f *testing.F) {
	f.Add(`{"title":"IMG_1.jpg","photoTakenTime":{"timestamp":"1577264400"},"geoData":{"latitude":48.8,"longitude":2.3}}`)
	f.Fuzz(func(t *testing.T, s string) {
		withinTime(t, 3*time.Second, func() {
			_, _, _ = ParseTakeoutJSON(strings.NewReader(s))
			x := NewJSONIndex()
			x.Add(strings.NewReader(s))
		})
	})
}

func FuzzNameTaken(f *testing.F) {
	for _, n := range []string{"IMG_20191225_090000.jpg", "PXL_20230301_101010123.jpg", "Screenshot_2024-01-02-03-04-05.png", "photo_12@24-12-2023_18-30-05.jpg", "IMG-20200101-WA0001.jpg"} {
		f.Add(n)
	}
	f.Fuzz(func(t *testing.T, name string) {
		withinTime(t, time.Second, func() { _, _ = NameTaken(name) })
	})
}

// The Takeout index finds a sidecar however the names are shaped, in time.
func FuzzTakeoutLookup(f *testing.F) {
	f.Add("Photos from 2019/IMG_1.jpg", "IMG_1.jpg", "Photos from 2019/IMG_1(1).jpg")
	f.Fuzz(func(t *testing.T, entry, title, look string) {
		withinTime(t, time.Second, func() {
			x := NewTakeoutIndex()
			x.Add(entry, title, Meta{Taken: time.Unix(1, 0)})
			_, _ = x.Lookup(look)
		})
	})
}

// withinTime fails the input when fn takes longer than d: a crafted file
// that keeps a processor busy is as much a fault as one that crashes.
func withinTime(t *testing.T, d time.Duration, fn func()) {
	t.Helper()
	done := make(chan struct{})
	go func() { defer close(done); fn() }()
	select {
	case <-done:
	case <-time.After(d):
		t.Fatalf("took longer than %s", d)
	}
}
