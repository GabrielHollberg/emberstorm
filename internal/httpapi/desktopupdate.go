package httpapi

import (
	"sync"
	"time"

	"github.com/GabrielHollberg/soundstorm/internal/desktoprelease"
	"github.com/GabrielHollberg/soundstorm/internal/version"
)

// Is a newer EmberStorm out? For a computer install (a box has its own
// updates, boxupdates.go): the newest release on GitHub, its list checked as
// signed by the release key exactly as the installers check it, compared with
// the release this install came from (SOUNDSTORM_RELEASE_SERIAL, which the
// installers write) - or, for an install from before they wrote it, with the
// date its own build was made. The owner is told in Settings, About, with how
// to update on this computer (2026-10-13, the owner: nothing said an update
// was out, so computer installs sat on whatever they first installed).
//
// Looked for at most twice a day, in the background of a session asked for,
// so a page never waits on GitHub. All GitHub learns is that an install
// looked. SOUNDSTORM_UPDATE_CHECK=off turns it off.

const desktopReleaseBase = "https://github.com/GabrielHollberg/emberstorm/releases/latest/download/"

type desktopUpdates struct {
	mu      sync.Mutex
	latest  *desktoprelease.Manifest
	checked time.Time
	busy    bool
	// fetch is desktoprelease.Get, or a stand-in in tests.
	fetch func(addr string, limit int64) ([]byte, error)
}

// newest answers the newest signed release known, and looks again in the
// background when the last look is twelve hours old (an hour after a
// failed one).
func (d *desktopUpdates) newest() *desktoprelease.Manifest {
	d.mu.Lock()
	defer d.mu.Unlock()
	wait := 12 * time.Hour
	if d.latest == nil {
		wait = time.Hour
	}
	if !d.busy && time.Since(d.checked) > wait {
		d.busy = true
		go d.look()
	}
	return d.latest
}

func (d *desktopUpdates) look() {
	defer func() {
		_ = recover()
		d.mu.Lock()
		d.busy = false
		d.checked = time.Now()
		d.mu.Unlock()
	}()
	get := d.fetch
	if get == nil {
		get = desktoprelease.Get
	}
	data, err := get(desktopReleaseBase+"desktop.json", 64<<10)
	if err != nil {
		return
	}
	sig, err := get(desktopReleaseBase+"desktop.json.sig", 4<<10)
	if err != nil {
		return
	}
	keys, err := desktoprelease.Keys()
	if err != nil {
		return
	}
	m, err := desktoprelease.Verify(data, sig, keys)
	if err != nil {
		return
	}
	d.mu.Lock()
	d.latest = m
	d.mu.Unlock()
}

// desktopUpdateFor answers what the owner is told: the newer release's
// version, or nil when this install is up to date or nothing is known.
func (s *Server) desktopUpdateFor() map[string]any {
	if s.caretakerSocket != "" || s.updateCheckOff {
		return nil
	}
	m := s.desktopRel.newest()
	if m == nil || !newerThanThis(m, s.releaseSerial, version.Commit, version.Date) {
		return nil
	}
	return map[string]any{"version": m.Version}
}

// newerThanThis decides whether a release is newer than this install: by the
// release it came from when known, else by when this build was made (a day's
// grace, as a release is made after the build it carries).
func newerThanThis(m *desktoprelease.Manifest, serial int64, commit, date string) bool {
	if serial > 0 {
		return m.Serial > serial
	}
	if commit != "" && m.Commit == commit {
		return false
	}
	built, err := time.Parse(time.RFC3339, date)
	if err != nil {
		return false
	}
	made, err := time.Parse(time.RFC3339, m.Created)
	if err != nil {
		return false
	}
	return made.After(built.Add(24 * time.Hour))
}
