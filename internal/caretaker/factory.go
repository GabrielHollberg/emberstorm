package caretaker

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// The factory's first start (the owner's design, 2026-10-11). A box put
// together at the factory is started once before it is boxed: its first
// start - every program unpacked from the built-in drive onto the storage
// drive, 15-30 minutes on the real hardware - happens there, not at the
// buyer's, and is the test that every part of it works. The factory stick
// leaves a mark on the box it installs (FactoryMark); at that first start the
// caretaker waits for EmberStorm to answer with every source, then starts the
// box over as new - accounts, settings and what the backends set up all
// gone, the unpacked programs kept - and switches it off. The buyer's first
// start is then a minute or two. A box that does not pass keeps its mark and
// says so on its screen (FactoryStatus, screen.sh); switched off and on, it is
// tested again.

// factoryWait is how long the first start may take before the test fails.
var factoryWait = 60 * time.Minute

// factoryPoll is how often EmberStorm is asked meanwhile.
var factoryPoll = 15 * time.Second

func (u *Updater) factoryPending() bool {
	_, err := os.Stat(u.cfg.FactoryMark)
	return err == nil
}

// factoryShow puts a line on the box's screen.
func (u *Updater) factoryShow(text string) {
	_ = os.MkdirAll(filepath.Dir(u.cfg.FactoryStatus), 0o755)
	_ = writeFile(u.cfg.FactoryStatus, []byte(text+"\n"))
}

// factoryTest waits for every part of EmberStorm to start, then makes the
// box new and switches it off. It answers whether the box passed.
func (u *Updater) factoryTest(ctx context.Context) bool {
	want := u.cfg.FactorySources
	u.log.Warn("factory test: waiting for EmberStorm", "sources", want)
	deadline := time.Now().Add(factoryWait)
	seen := 0
	for {
		h, err := u.health(ctx)
		if err == nil && h.Status == "ok" {
			seen = h.Sources
			if h.Sources >= want {
				break
			}
		}
		u.factoryShow(fmt.Sprintf("FACTORY TEST: starting every part of EmberStorm (%d of %d so far)...", seen, want))
		if time.Now().After(deadline) {
			u.factoryShow(fmt.Sprintf("FACTORY TEST FAILED: only %d of %d parts of EmberStorm started in %d minutes. Switch the box off and on to test it again, or set it aside.",
				seen, want, int(factoryWait/time.Minute)))
			u.log.Error("factory test failed", "sources", seen, "want", want)
			return false
		}
		select {
		case <-ctx.Done():
			return false
		case <-time.After(factoryPoll):
		}
	}
	u.factoryShow("FACTORY TEST PASSED. Making the box new for its buyer...")
	u.log.Warn("factory test passed: starting the box over as new")
	if err := u.reset(ctx, ResetStartOver, false); err != nil {
		u.factoryShow("FACTORY TEST: the box passed, but could not be made new again (" + err.Error() + "). Switch it off and on to try again.")
		u.log.Error("factory test: could not start over", "err", err)
		return false
	}
	if err := os.Remove(u.cfg.FactoryMark); err != nil && !os.IsNotExist(err) {
		u.factoryShow("FACTORY TEST: the box passed, but its factory mark could not be removed. Switch it off and on to try again.")
		return false
	}
	u.factoryShow("FACTORY TEST PASSED. The box is ready to pack - switching off.")
	_ = u.run(ctx, "sync")
	_ = u.run(ctx, "systemctl", "poweroff")
	return true
}
