package pdf

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// Fuzzing the PDF metadata reader: go test -fuzz=FuzzOpen ./internal/pdf.

func FuzzOpen(f *testing.F) {
	f.Add([]byte("%PDF-1.4\n1 0 obj << /Title (Dune) /Author (Frank Herbert) >> endobj\ntrailer << /Info 1 0 R >>"))
	f.Add([]byte("%PDF-1.7\n<x:xmpmeta><rdf:RDF><rdf:Description><dc:title><rdf:Alt><rdf:li>T</rdf:li></rdf:Alt></dc:title></rdf:Description></rdf:RDF></x:xmpmeta>"))
	f.Add([]byte("%PDF-1.4\n/Title <FEFF00440075006E0065>"))
	f.Fuzz(func(t *testing.T, data []byte) {
		p := filepath.Join(t.TempDir(), "x.pdf")
		if err := os.WriteFile(p, data, 0o600); err != nil {
			t.Skip()
		}
		withinTime(t, 3*time.Second, func() { _, _ = Open(p) })
	})
}

func FuzzFromFilename(f *testing.F) {
	f.Add("Dune - Frank Herbert (1965).pdf")
	f.Add("Herbert, Frank - Dune.pdf")
	f.Fuzz(func(t *testing.T, name string) {
		withinTime(t, time.Second, func() { _ = FromFilename(name) })
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
