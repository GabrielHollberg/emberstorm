package caretaker

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"html"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// A box getting ready is seen at once (the owner's design, 2026-10-11): while
// its first start unpacks EmberStorm's programs (images.sh, which writes how
// far it has got to Progress), nothing answered on EmberStorm's port, so the
// phone's search found nothing for up to half an hour and the box's screen
// said only "starting". The caretaker runs from the first seconds, so it
// answers there meanwhile - the phone's search (/healthz, status "starting",
// with the share done and what it is doing) and a browser at emberstorm.local
// (a page with the bar) - and lets go of the ports before EmberStorm starts
// (images.sh says "starting"; up.sh waits for StartingOpen to go). Only while
// there is unpacking to do, and only on a port free: a box already set up
// never sees it. It says nothing private: no setup code, no name.

// Progress is what the first start says of itself.
type Progress struct {
	// Phase is "images" while programs are unpacked, "starting" once
	// EmberStorm is being started.
	Phase   string `json:"phase"`
	Step    string `json:"step"`
	Percent int    `json:"percent"`
}

// ReadProgress reads images.sh's file: key=value lines.
func ReadProgress(path string) (Progress, bool) {
	f, err := os.Open(path)
	if err != nil {
		return Progress{}, false
	}
	defer f.Close()
	var p Progress
	var done, total float64
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		k, v, ok := strings.Cut(sc.Text(), "=")
		if !ok {
			continue
		}
		switch k {
		case "phase":
			p.Phase = v
		case "step":
			p.Step = v
		case "done":
			done, _ = strconv.ParseFloat(v, 64)
		case "total":
			total, _ = strconv.ParseFloat(v, 64)
		}
	}
	if total > 0 {
		p.Percent = int(done * 100 / total)
	}
	if p.Percent < 0 {
		p.Percent = 0
	}
	if p.Percent > 100 {
		p.Percent = 100
	}
	return p, p.Phase != ""
}

// startingPoll is how often the progress file is looked at.
var startingPoll = time.Second

// serveStarting answers on StartingPorts while the first start unpacks.
func (u *Updater) serveStarting(ctx context.Context) {
	defer func() {
		if r := recover(); r != nil {
			u.log.Error("the getting-ready answer stopped", "panic", r)
		}
		_ = os.Remove(u.cfg.StartingOpen)
	}()
	var servers []*http.Server
	stop := func() {
		for _, s := range servers {
			_ = s.Close()
		}
		if servers != nil {
			u.log.Info("letting EmberStorm have its ports")
		}
		servers = nil
		_ = os.Remove(u.cfg.StartingOpen)
	}
	defer stop()
	for {
		p, ok := ReadProgress(u.cfg.Progress)
		want := ok && p.Phase == "images"
		switch {
		case want && servers == nil:
			for _, addr := range u.cfg.StartingPorts {
				ln, err := net.Listen("tcp", addr)
				if err != nil {
					continue // in use: EmberStorm, or anything else, has it
				}
				srv := &http.Server{Handler: u.startingHandler(), ReadHeaderTimeout: 5 * time.Second,
					ReadTimeout: 10 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 10 * time.Second}
				go func() { _ = srv.Serve(ln) }()
				servers = append(servers, srv)
			}
			if servers != nil {
				_ = os.MkdirAll(filepath.Dir(u.cfg.StartingOpen), 0o755)
				_ = writeFile(u.cfg.StartingOpen, []byte("1\n"))
				u.log.Info("answering while the box gets ready", "ports", len(servers))
			}
		case !want && servers != nil:
			stop()
		}
		select {
		case <-ctx.Done():
			return
		case <-time.After(startingPoll):
		}
	}
}

// startingHandler is what a box getting ready answers.
func (u *Updater) startingHandler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, _ := ReadProgress(u.cfg.Progress)
		step := p.Step
		if step == "" {
			step = "Getting ready"
		}
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if r.URL.Path == "/healthz" {
			w.Header().Set("Content-Type", "application/json")
			// What the apps' search reads (ServerDiscovery): starting, not
			// yet a server to sign in to; an older app, wanting "ok",
			// passes it over until EmberStorm answers.
			_ = json.NewEncoder(w).Encode(map[string]any{
				"status":   "starting",
				"starting": true,
				"setUp":    false,
				"percent":  p.Percent,
				"step":     step,
			})
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'")
		fmt.Fprintf(w, `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="5"><title>EmberStorm is getting ready</title>
<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;background:#000;color:#e8eaf0;font:16px/1.5 system-ui,sans-serif}
main{max-width:28rem;padding:2rem;text-align:center}h1{font-size:1.4rem;margin:0 0 .5rem}p{color:#a8b0c0}
.bar{height:10px;border-radius:5px;background:#1d2230;overflow:hidden;margin:1.5rem 0 .5rem}.bar div{height:100%%;background:#5b9cff;width:%d%%}</style></head>
<body><main><h1>Your new EmberStorm is getting ready</h1><p>%s</p>
<div class="bar"><div></div></div><p>%d%%</p>
<p>The first start takes a few minutes. This page carries on by itself when it is ready.</p></main></body></html>`,
			p.Percent, html.EscapeString(step), p.Percent)
	})
}
