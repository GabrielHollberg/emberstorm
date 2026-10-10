package caretaker

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// What a power cut part way through an update leaves: the new images file
// written, the release noted as under way, and the snapshot made.
func cutShort(t *testing.T, b *box, m *Manifest, before string) string {
	t.Helper()
	write := func(p, s string) {
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, []byte(s), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	snap := b.u.cfg.Volumes + "-before-5"
	write(filepath.Join(snap, "accounts"), "the household's accounts")
	write(filepath.Join(b.u.cfg.Volumes, "accounts"), "changed by the new version")
	write(filepath.Join(b.dir, "compose.images.yml"), string(ImagesFile(m)))
	write(filepath.Join(b.u.cfg.StateDir, previousImages), before)
	if err := b.u.writePending(pending{Kind: "update", Manifest: m, Snapshot: snap, HadPrevious: true}); err != nil {
		t.Fatal(err)
	}
	return snap
}

func TestAnUpdateCutShortIsKeptWhenItComesUpHealthy(t *testing.T) {
	b := newBox(t)
	m := release(5)
	cutShort(t, b, m, "# before\n")
	u := New(b.u.cfg, b.u.log)
	u.run, u.output = b.u.run, b.u.output
	u.recoverPending(context.Background())
	if s := u.Status(); s.Current == nil || s.Current.Serial != 5 {
		t.Fatalf("status %+v", s)
	}
	if _, ok := u.readPending(); ok {
		t.Fatal("the update was still noted as under way")
	}
}

func TestAnUpdateCutShortIsUndoneWhenItIsNotHealthy(t *testing.T) {
	b := newBox(t)
	m := release(5)
	snap := cutShort(t, b, m, "# before\n")
	b.u.saveBaseline(9) // the box last came up with nine
	b.healthy.Store(false)
	// Cut short again, in the rollback: the volumes set aside, the copy not
	// yet put back.
	if err := os.Rename(b.u.cfg.Volumes, b.u.cfg.Volumes+"-failed-x"); err != nil {
		t.Fatal(err)
	}
	u := New(b.u.cfg, b.u.log)
	u.run, u.output = b.u.run, b.u.output
	u.recoverPending(context.Background())
	if b.images() != "# before\n" {
		t.Fatalf("the images from before were not put back:\n%s", b.images())
	}
	got, err := os.ReadFile(filepath.Join(b.u.cfg.Volumes, "accounts"))
	if err != nil || string(got) != "the household's accounts" {
		t.Fatalf("the volumes were not put back: %q %v", got, err)
	}
	if exists(snap) {
		t.Fatal("the snapshot was left where it was")
	}
	if s := u.Status(); s.State != "rolled-back" || s.Current != nil {
		t.Fatalf("status %+v", s)
	}
	if _, ok := u.readPending(); ok {
		t.Fatal("the update was still noted as under way")
	}
}

func TestAResetCutShortIsDoneAgain(t *testing.T) {
	b := newBox(t)
	b.u.cfg.Cache = filepath.Join(b.dir, "cache")
	b.u.cfg.Library = filepath.Join(b.dir, "library")
	for _, d := range []string{b.u.cfg.Volumes, b.u.cfg.Cache, b.u.cfg.Library} {
		if err := os.MkdirAll(filepath.Join(d, "kept"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	left := filepath.Join(b.u.cfg.Volumes, "kept", "accounts.json")
	if err := os.WriteFile(left, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := b.u.writePending(pending{Kind: "reset", Mode: ResetStartOver}); err != nil {
		t.Fatal(err)
	}
	b.u.recoverPending(context.Background())
	if exists(left) {
		t.Fatal("the reset was not done again")
	}
	if _, ok := b.u.readPending(); ok {
		t.Fatal("the reset was still noted as under way")
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	if !strings.Contains(strings.Join(b.ran, "\n"), "up down") || b.ran[len(b.ran)-1] != "up" {
		t.Fatalf("ran %q", b.ran)
	}
}

// A snapshot never goes onto one already there: btrfs would put it inside.
func TestASnapshotHasANameOfItsOwn(t *testing.T) {
	b := newBox(t)
	first := b.u.snapshotPath(5)
	if err := os.MkdirAll(first, 0o755); err != nil {
		t.Fatal(err)
	}
	if again := b.u.snapshotPath(5); again == first || !strings.HasPrefix(again, first+"-") {
		t.Fatalf("%q then %q", first, again)
	}
}
