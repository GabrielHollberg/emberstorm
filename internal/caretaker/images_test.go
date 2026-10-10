package caretaker

import (
	"context"
	"errors"
	"io"
	"log/slog"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

// fakeDocker is a pretend image store: images by id with their repository,
// references that name them, and containers using some.
type fakeDocker struct {
	repo       map[string]string // image id -> repository
	refs       map[string]string // reference -> image id
	containers map[string]string // container id -> image id
	removed    []string
}

func (f *fakeDocker) output(_ context.Context, name string, args ...string) ([]byte, error) {
	cmd := strings.Join(args, " ")
	switch {
	case strings.HasPrefix(cmd, "image inspect"):
		if id, ok := f.refs[args[len(args)-1]]; ok {
			return []byte(id + "\n"), nil
		}
		return nil, errors.New("no such image")
	case strings.HasPrefix(cmd, "container ls"):
		var ids []string
		for c := range f.containers {
			ids = append(ids, c)
		}
		return []byte(strings.Join(ids, "\n")), nil
	case strings.HasPrefix(cmd, "container inspect"):
		var used []string
		for _, c := range args[3:] {
			used = append(used, f.containers[c])
		}
		return []byte(strings.Join(used, "\n")), nil
	case strings.HasPrefix(cmd, "image ls"):
		var lines []string
		for id, repo := range f.repo {
			lines = append(lines, id+" "+repo)
		}
		return []byte(strings.Join(lines, "\n")), nil
	}
	return nil, errors.New("unexpected: " + name + " " + cmd)
}

func (f *fakeDocker) run(_ context.Context, name string, args ...string) error {
	if name == "docker" && len(args) == 3 && args[0] == "image" && args[1] == "rm" {
		id := args[2]
		for _, used := range f.containers {
			if used == id {
				return errors.New("image is being used by a container")
			}
		}
		f.removed = append(f.removed, id)
		delete(f.repo, id)
	}
	return nil
}

func releaseOf(serial int64, d string) *Manifest {
	m := release(serial)
	m.Images = map[string]string{
		"soundstorm": "ghcr.io/gabrielhollberg/soundstorm@sha256:" + strings.Repeat(d, 64),
		"navidrome":  "docker.io/deluan/navidrome@sha256:" + strings.Repeat(d, 64),
	}
	return m
}

func TestOldVersionsAreRemovedAfterAnUpdate(t *testing.T) {
	dir := t.TempDir()
	u := New(Config{ComposeDir: dir, StateDir: filepath.Join(dir, "state")}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	f := &fakeDocker{
		repo: map[string]string{
			"sha256:built-ss": "soundstorm-box/soundstorm", "sha256:built-nd": "soundstorm-box/navidrome",
			"sha256:r2-ss": "ghcr.io/gabrielhollberg/soundstorm", "sha256:r2-nd": "deluan/navidrome",
			"sha256:alpine": "alpine", // nothing to do with a release: never touched
		},
		refs: map[string]string{
			"soundstorm-box/soundstorm:built": "sha256:built-ss", "soundstorm-box/navidrome:built": "sha256:built-nd",
		},
		containers: map[string]string{"c-ss": "sha256:r2-ss", "c-nd": "sha256:r2-nd"},
	}
	u.output, u.run = f.output, f.run
	r2, r3 := releaseOf(2, "2"), releaseOf(3, "3")
	f.refs[r2.Images["soundstorm"]], f.refs[r2.Images["navidrome"]] = "sha256:r2-ss", "sha256:r2-nd"
	built := []byte("services:\n  soundstorm:\n    image: soundstorm-box/soundstorm:built\n  navidrome:\n    image: soundstorm-box/navidrome:built\n")
	ctx := context.Background()

	// The first update keeps the images the box was built with: one step back.
	if n := u.pruneImages(ctx, r2, nil, built); n != 0 {
		t.Fatalf("the first update removed %d images: %v", n, f.removed)
	}

	// The second takes them; release 2 is now the step back.
	f.repo["sha256:r3-ss"], f.repo["sha256:r3-nd"] = "ghcr.io/gabrielhollberg/soundstorm", "deluan/navidrome"
	f.refs[r3.Images["soundstorm"]], f.refs[r3.Images["navidrome"]] = "sha256:r3-ss", "sha256:r3-nd"
	f.containers = map[string]string{"c-ss": "sha256:r3-ss", "c-nd": "sha256:r3-nd", "stopped": "sha256:built-nd"}
	u.pruneImages(ctx, r3, r2, ImagesFile(r2))
	sort.Strings(f.removed)
	if strings.Join(f.removed, ",") != "sha256:built-ss" {
		t.Fatalf("removed %v; want only the built soundstorm image (navidrome's is used by a container)", f.removed)
	}

	// The third takes release 2's.
	f.removed = nil
	delete(f.containers, "stopped")
	r4 := releaseOf(4, "4")
	f.repo["sha256:r4-ss"], f.repo["sha256:r4-nd"] = "ghcr.io/gabrielhollberg/soundstorm", "deluan/navidrome"
	f.refs[r4.Images["soundstorm"]], f.refs[r4.Images["navidrome"]] = "sha256:r4-ss", "sha256:r4-nd"
	f.containers = map[string]string{"c-ss": "sha256:r4-ss", "c-nd": "sha256:r4-nd"}
	u.pruneImages(ctx, r4, r3, ImagesFile(r3))
	sort.Strings(f.removed)
	if strings.Join(f.removed, ",") != "sha256:built-nd,sha256:r2-nd,sha256:r2-ss" {
		t.Fatalf("removed %v", f.removed)
	}
	if _, ok := f.repo["sha256:alpine"]; !ok {
		t.Fatal("an image no release named was removed")
	}
	if _, ok := f.repo["sha256:r3-ss"]; !ok {
		t.Fatal("the step back was removed")
	}
}

func TestNothingIsRemovedWhenUseCannotBeTold(t *testing.T) {
	dir := t.TempDir()
	u := New(Config{ComposeDir: dir, StateDir: filepath.Join(dir, "state")}, slog.New(slog.NewTextHandler(io.Discard, nil)))
	u.output = func(context.Context, string, ...string) ([]byte, error) {
		return nil, errors.New("docker is not answering")
	}
	u.run = func(_ context.Context, name string, args ...string) error {
		t.Errorf("ran %s %v", name, args)
		return nil
	}
	if n := u.pruneImages(context.Background(), releaseOf(3, "3"), releaseOf(2, "2"), nil); n != 0 {
		t.Fatalf("removed %d", n)
	}
}

func TestRepositoriesAreReadAsDockerShowsThem(t *testing.T) {
	for ref, want := range map[string]string{
		"docker.io/deluan/navidrome@sha256:abc":       "deluan/navidrome",
		"ghcr.io/gabrielhollberg/soundstorm@sha256:a": "ghcr.io/gabrielhollberg/soundstorm",
		"docker.io/library/alpine:3":                  "alpine",
		"registry.example:5000/x/y:tag":               "registry.example:5000/x/y",
		"soundstorm-box/navidrome:built":              "soundstorm-box/navidrome",
	} {
		if got := repository(ref); got != want {
			t.Errorf("%s: %q, want %q", ref, got, want)
		}
	}
}
