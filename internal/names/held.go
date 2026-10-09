package names

import (
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/subtle"
	_ "embed"
	"strings"
	"sync"
	"time"
)

// Held names: names nobody can choose for a web address unless they were given
// a code for it (the owner's decision, 2026-10-06). Single first names and
// single surnames are scarce - only one person could ever have smith - so none
// of them go to whoever happens to ask first; combinations (gabrielhollberg,
// thehollbergs) stay open to everybody. Also held: the names the domain uses
// (reservedNames), anything carrying the product's name, and anything shaped
// like a server's code. Whoever asks is told only that a held name is not
// available, the same as a taken one - never why.
//
// The single names are the US Census 2010 surnames (every surname at least 100
// people have) and the Social Security Administration's first names (every
// name given to at least five babies in a year since 1880): public data, about
// 250,000 names, lowercased to letters only. Rarer surnames are not on it; any
// can be held by naming it in extraHeld or the service's codes.

//go:embed held-names.txt.gz
var heldNamesGz []byte

var (
	heldOnce  sync.Once
	heldNames map[string]struct{}
)

// extraHeld are names held though the public lists miss them.
var extraHeld = []string{"hollberg", "sphere"}

func loadHeld() {
	heldOnce.Do(func() {
		heldNames = map[string]struct{}{}
		zr, err := gzip.NewReader(bytes.NewReader(heldNamesGz))
		if err != nil {
			return
		}
		sc := bufio.NewScanner(zr)
		for sc.Scan() {
			if w := strings.TrimSpace(sc.Text()); w != "" {
				heldNames[w] = struct{}{}
			}
		}
		for _, w := range extraHeld {
			heldNames[w] = struct{}{}
		}
	})
}

// held reports whether a name is kept back from being chosen.
func held(name string) bool {
	loadHeld()
	if _, ok := heldNames[name]; ok {
		return true
	}
	return reservedNames[name] || strings.Contains(name, "soundstorm") || strings.Contains(name, "emberstorm") || validID(name)
}

// notAvailable is all anybody is told about a name they cannot have - held,
// reserved or taken alike.
const notAvailable = "That name isn't available. Try another."

// heldCodeOK says whether code is the one the owner gave out for a held name
// (NAMES_HELD_CODES). Capitals, spaces and dashes do not count, as with the
// setup code: a phone keyboard capitalising the first letter must not refuse it.
func (s *Server) heldCodeOK(name, code string) bool {
	if s.limits.spent("held-code:"+name, heldCodeRate) {
		return false
	}
	want, ok := s.HeldCodes[name]
	want, code = plainCode(want), plainCode(code)
	if !ok || want == "" || code == "" {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(code), []byte(want)) == 1
}

// heldCodeTry is heldCodeOK counting wrong tries: ten a day for a name,
// from anywhere, as the codes are what the owner types and may be short.
func (s *Server) heldCodeTry(name, code string) bool {
	if s.heldCodeOK(name, code) {
		return true
	}
	if code != "" {
		s.limits.allow("held-code:"+name, heldCodeRate)
	}
	return false
}

var heldCodeRate = rate{n: 10, window: 24 * time.Hour}

// plainCode is a code with its capitals, spaces and dashes set aside.
func plainCode(code string) string {
	return strings.Map(func(r rune) rune {
		if r == ' ' || r == '-' || r == '\t' {
			return -1
		}
		return r
	}, strings.ToLower(code))
}

// ParseHeldCodes reads "name=code,name=code" (NAMES_HELD_CODES): the held
// names the owner is giving out, each with its code. A name given a code is
// held whether or not it is on the lists.
func ParseHeldCodes(s string) map[string]string {
	out := map[string]string{}
	for _, part := range strings.Split(s, ",") {
		name, code, ok := strings.Cut(strings.TrimSpace(part), "=")
		name = strings.ToLower(strings.TrimSpace(name))
		code = strings.TrimSpace(code)
		if ok && name != "" && code != "" {
			out[name] = code
		}
	}
	return out
}
