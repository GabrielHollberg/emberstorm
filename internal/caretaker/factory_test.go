package caretaker

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// A factory stick's box: once every part of EmberStorm answers, it is made
// new - stopped, its accounts and settings emptied, not started again - its
// mark taken away, and switched off. One that never gets there keeps its mark
// and says so on its screen.
func TestTheFactoryTestMakesTheBoxNewAndSwitchesItOff(t *testing.T) {
	b := newBox(t)
	b.u.cfg.FactoryMark = filepath.Join(b.dir, "factory-test")
	b.u.cfg.FactoryStatus = filepath.Join(b.dir, "factory")
	b.u.cfg.Cache = filepath.Join(b.dir, "cache")
	b.u.cfg.Library = filepath.Join(b.dir, "library")
	os.MkdirAll(filepath.Join(b.u.cfg.Volumes, "accounts"), 0o755)
	os.WriteFile(filepath.Join(b.u.cfg.Volumes, "accounts", "state.json"), []byte("{}"), 0o600)
	os.WriteFile(b.u.cfg.FactoryMark, nil, 0o600)
	factoryPoll = 10 * time.Millisecond

	if !b.u.factoryPending() || !b.u.factoryTest(context.Background()) {
		t.Fatal("a healthy box did not pass")
	}
	if b.u.factoryPending() {
		t.Fatal("the factory mark is still there")
	}
	if _, err := os.Stat(filepath.Join(b.u.cfg.Volumes, "accounts", "state.json")); err == nil {
		t.Fatal("what the first start set up was not emptied")
	}
	b.mu.Lock()
	ran := strings.Join(b.ran, " | ")
	b.mu.Unlock()
	if !strings.Contains(ran, "up down") || strings.HasSuffix(ran, "| up") || !strings.HasSuffix(ran, "systemctl poweroff") {
		t.Fatalf("ran %s", ran)
	}
	for _, r := range strings.Split(ran, " | ") {
		if r == "up" {
			t.Fatalf("EmberStorm was started again: %s", ran)
		}
	}
	if s, _ := os.ReadFile(b.u.cfg.FactoryStatus); !strings.Contains(string(s), "PASSED") {
		t.Fatalf("the screen says %q", s)
	}
}

func TestAFactoryBoxThatNeverStartsFailsItsTest(t *testing.T) {
	b := newBox(t)
	b.u.cfg.FactoryMark = filepath.Join(b.dir, "factory-test")
	b.u.cfg.FactoryStatus = filepath.Join(b.dir, "factory")
	os.WriteFile(b.u.cfg.FactoryMark, nil, 0o600)
	b.healthy.Store(false) // 4 sources of 9
	factoryPoll, factoryWait = 10*time.Millisecond, 50*time.Millisecond
	defer func() { factoryWait = 60 * time.Minute }()

	if b.u.factoryTest(context.Background()) {
		t.Fatal("a box with 4 of 9 parts passed")
	}
	if !b.u.factoryPending() {
		t.Fatal("the mark went with the test failed")
	}
	if s, _ := os.ReadFile(b.u.cfg.FactoryStatus); !strings.Contains(string(s), "FAILED") || !strings.Contains(string(s), "4 of 9") {
		t.Fatalf("the screen says %q", s)
	}
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, r := range b.ran {
		if r == "up down" || r == "systemctl poweroff" {
			t.Fatalf("a failed box was reset or switched off: %v", b.ran)
		}
	}
}

// While the first start unpacks, the box answers the phone's search with how
// far it has got, and lets go of the port once EmberStorm is to start.
func TestABoxGettingReadyAnswersUntilEmberStormStarts(t *testing.T) {
	b := newBox(t)
	ln, _ := net.Listen("tcp", "127.0.0.1:0")
	addr := ln.Addr().String()
	ln.Close()
	b.u.cfg.StartingPorts = []string{addr}
	b.u.cfg.Progress = filepath.Join(b.dir, "progress")
	b.u.cfg.StartingOpen = filepath.Join(b.dir, "starting-open")
	startingPoll = 10 * time.Millisecond
	os.WriteFile(b.u.cfg.Progress, []byte("phase=images\nstep=Preparing EmberStorm (3 of 14)\ndone=300\ntotal=1000\n"), 0o644)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go b.u.serveStarting(ctx)

	var answer struct {
		Status  string
		Percent int
		Step    string
		SetUp   bool
	}
	deadline := time.Now().Add(2 * time.Second)
	for {
		resp, err := http.Get("http://" + addr + "/healthz")
		if err == nil {
			json.NewDecoder(resp.Body).Decode(&answer)
			resp.Body.Close()
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("nothing answered while the box was getting ready")
		}
		time.Sleep(20 * time.Millisecond)
	}
	if answer.Status != "starting" || answer.Percent != 30 || answer.Step != "Preparing EmberStorm (3 of 14)" || answer.SetUp {
		t.Fatalf("answered %+v", answer)
	}
	if _, err := os.Stat(b.u.cfg.StartingOpen); err != nil {
		t.Fatal("it did not say it was answering")
	}

	os.WriteFile(b.u.cfg.Progress, []byte("phase=starting\nstep=Starting EmberStorm\n"), 0o644)
	deadline = time.Now().Add(2 * time.Second)
	for {
		_, statErr := os.Stat(b.u.cfg.StartingOpen)
		free, err := net.Listen("tcp", addr)
		if err == nil {
			free.Close()
		}
		if err == nil && statErr != nil {
			break // the port is EmberStorm's to take
		}
		if time.Now().After(deadline) {
			t.Fatal("the port was not let go once EmberStorm was to start")
		}
		time.Sleep(20 * time.Millisecond)
	}
}
