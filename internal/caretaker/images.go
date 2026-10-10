package caretaker

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

// Old versions are removed once an update is installed and healthy. Every
// update downloads its images before anything stops, so the box can go back
// if the new version will not start - and nothing took the old ones away
// after, so the 64GB system drive, which holds Docker's images (the data
// lives on the data drive), filled a few hundred MB to a couple of GB at each
// update until an update had nowhere to download to.
//
// Kept: what the running release names, what the release before it named (one
// step back, as the newest snapshot is kept), and anything a container still
// uses. Only images of the repositories the box's releases have used are ever
// touched, so nothing else on the box is - and nothing is forced: an image
// Docker says is in use stays.

// Output runs a command on the box and answers what it printed. Tests replace
// it.
type Output func(ctx context.Context, name string, args ...string) ([]byte, error)

func execOutput(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).Output()
}

// imageRefs reads the image lines of a compose.images.yml.
func imageRefs(file []byte) []string {
	var refs []string
	for _, line := range strings.Split(string(file), "\n") {
		line = strings.TrimSpace(line)
		if ref, ok := strings.CutPrefix(line, "image:"); ok {
			if ref = strings.TrimSpace(ref); ref != "" {
				refs = append(refs, ref)
			}
		}
	}
	return refs
}

// repository is a reference's repository as `docker image ls` shows it:
// without its digest or tag, and without Docker Hub's own prefixes.
func repository(ref string) string {
	if i := strings.Index(ref, "@"); i >= 0 {
		ref = ref[:i]
	}
	if i := strings.LastIndex(ref, ":"); i > strings.LastIndex(ref, "/") {
		ref = ref[:i]
	}
	for _, prefix := range []string{"docker.io/", "index.docker.io/"} {
		ref = strings.TrimPrefix(ref, prefix)
	}
	return strings.TrimPrefix(ref, "library/")
}

// knownRepositories adds refs' repositories to those kept in the state folder
// (the box's own names for the images it was built with included, so they
// are cleaned up once two releases have replaced them) and answers them all.
func (u *Updater) knownRepositories(refs []string) map[string]bool {
	path := filepath.Join(u.cfg.StateDir, "repositories.json")
	known := map[string]bool{}
	if data, err := os.ReadFile(path); err == nil {
		var list []string
		if json.Unmarshal(data, &list) == nil {
			for _, r := range list {
				known[r] = true
			}
		}
	}
	for _, ref := range refs {
		if r := repository(ref); r != "" {
			known[r] = true
		}
	}
	list := make([]string, 0, len(known))
	for r := range known {
		list = append(list, r)
	}
	sort.Strings(list)
	if data, err := json.Marshal(list); err == nil {
		_ = os.MkdirAll(u.cfg.StateDir, 0o755)
		_ = writeFile(path, data)
	}
	return known
}

// pruneImages removes the images of known repositories that neither the
// running release (now), the one before it (before, and the images file it
// ran, beforeFile) nor any container uses. It answers how many it removed.
func (u *Updater) pruneImages(ctx context.Context, now, before *Manifest, beforeFile []byte) int {
	var refs []string
	for _, m := range []*Manifest{now, before} {
		if m == nil {
			continue
		}
		for _, ref := range m.Images {
			refs = append(refs, ref)
		}
	}
	refs = append(refs, imageRefs(beforeFile)...)
	known := u.knownRepositories(refs)

	keep := map[string]bool{}
	for _, ref := range refs {
		if out, err := u.output(ctx, "docker", "image", "inspect", "--format", "{{.Id}}", ref); err == nil {
			keep[strings.TrimSpace(string(out))] = true
		}
	}
	if out, err := u.output(ctx, "docker", "container", "ls", "-aq", "--no-trunc"); err == nil {
		if ids := strings.Fields(string(out)); len(ids) > 0 {
			args := append([]string{"container", "inspect", "--format", "{{.Image}}"}, ids...)
			if used, err := u.output(ctx, "docker", args...); err == nil {
				for _, id := range strings.Fields(string(used)) {
					keep[id] = true
				}
			}
		}
	} else {
		// Not knowing what is in use, remove nothing.
		return 0
	}

	out, err := u.output(ctx, "docker", "image", "ls", "--no-trunc", "--format", "{{.ID}} {{.Repository}}")
	if err != nil {
		return 0
	}
	removed := 0
	seen := map[string]bool{}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		id, repo := fields[0], fields[1]
		if keep[id] || seen[id] || !known[repo] {
			continue
		}
		seen[id] = true
		if err := u.run(ctx, "docker", "image", "rm", id); err == nil {
			removed++
		}
	}
	return removed
}
