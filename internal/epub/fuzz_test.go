package epub

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Fuzzing the EPUB reader: go test -fuzz=FuzzParseOPF ./internal/epub.

const seedOPF = `<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>T</dc:title><dc:creator>A</dc:creator><meta name="cover" content="c"/></metadata><manifest><item id="c" href="c.jpg" media-type="image/jpeg"/><item id="x" href="x.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="x"/></spine></package>`

func FuzzParseOPF(f *testing.F) {
	f.Add([]byte(seedOPF))
	f.Fuzz(func(t *testing.T, data []byte) {
		withinTime(t, 3*time.Second, func() { _, _, _ = ParseOPF(data, "OEBPS") })
	})
}

func FuzzOpen(f *testing.F) {
	var b bytes.Buffer
	z := zip.NewWriter(&b)
	for name, body := range map[string]string{
		"mimetype":               "application/epub+zip",
		"META-INF/container.xml": `<container><rootfiles><rootfile full-path="OEBPS/c.opf"/></rootfiles></container>`,
		"OEBPS/c.opf":            seedOPF,
	} {
		w, _ := z.Create(name)
		w.Write([]byte(body))
	}
	z.Close()
	f.Add(b.Bytes())
	f.Fuzz(func(t *testing.T, data []byte) {
		p := filepath.Join(t.TempDir(), "b.epub")
		if err := os.WriteFile(p, data, 0o600); err != nil {
			t.Skip()
		}
		withinTime(t, 5*time.Second, func() {
			if book, err := Open(p); err == nil && book != nil {
				_, _, _ = book.Cover()
				for i, e := range book.Entries() {
					if i > 20 {
						break
					}
					_, _, _ = book.Resource(e.Name)
				}
				book.Close()
			}
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
