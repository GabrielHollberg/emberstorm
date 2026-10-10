package collections

import "testing"

func TestPrefsAreKeptAndBounded(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	speed := 1.5
	off := false
	if _, err := s.ChangePrefs("u1", PrefsChange{
		Pills:     map[string][]string{"music": {"albums", "songs"}},
		Highlight: &off,
		BookSpeed: &speed,
	}); err != nil {
		t.Fatal(err)
	}
	// A change to one thing leaves the others alone.
	if _, err := s.ChangePrefs("u1", PrefsChange{Pills: map[string][]string{"books": {"ebook"}}}); err != nil {
		t.Fatal(err)
	}
	p, _ := s.Prefs("u1")
	if p.BookSpeed != 1.5 || p.Highlight == nil || *p.Highlight || len(p.Pills) != 2 || p.Pills["music"][0] != "albums" {
		t.Errorf("prefs = %+v", p)
	}

	fast := 9.0
	if _, err := s.ChangePrefs("u1", PrefsChange{BookSpeed: &fast}); err != ErrBadPrefs {
		t.Errorf("a speed of 9 was allowed: %v", err)
	}
	long := make([]string, 50)
	for i := range long {
		long[i] = "x"
	}
	if _, err := s.ChangePrefs("u1", PrefsChange{Pills: map[string][]string{"music": long}}); err != ErrBadPrefs {
		t.Errorf("fifty pills were allowed: %v", err)
	}
	if other, _ := s.Prefs("u2"); other.BookSpeed != 0 || other.Pills != nil {
		t.Errorf("one person's preferences reached another: %+v", other)
	}
}

// The welcome remembers the steps answered, and only names of its own.
func TestTheWelcomesStepsAreKept(t *testing.T) {
	s, err := Open(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if _, err := s.ChangePrefs("u1", PrefsChange{WelcomeSeen: []string{"address", "media"}}); err != nil {
		t.Fatal(err)
	}
	if p, _ := s.Prefs("u1"); len(p.WelcomeSeen) != 2 || p.WelcomeSeen[1] != "media" {
		t.Errorf("welcomeSeen = %v", p.WelcomeSeen)
	}
	if _, err := s.ChangePrefs("u1", PrefsChange{WelcomeSeen: []string{"address", "anything"}}); err != ErrBadPrefs {
		t.Errorf("a made-up step was kept: %v", err)
	}
	if p, _ := s.Prefs("u1"); len(p.WelcomeSeen) != 2 {
		t.Errorf("a refused change touched what was kept: %v", p.WelcomeSeen)
	}
}
