package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/GabrielHollberg/soundstorm/internal/names"
)

// Finding the server from soundstorm.dev (names/find.go): whether the website
// may find it from the home's own internet connection ("Open my SoundStorm"),
// and an address of the owner's choosing, hollberg.soundstorm.dev, held by the
// name service. Owner only, both.

// webNamesAvailable reports whether this install has the name service at all:
// auto HTTPS, the only mode that registers with it.
func (s *Server) webNamesAvailable() bool {
	return s.claimWebName != nil && s.releaseWebName != nil && s.remoteStatus != nil && s.remoteStatus().Available
}

// handleSetFindable turns "Open my SoundStorm" on or off: PUT {"enabled": bool}.
func (s *Server) handleSetFindable(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Enabled bool `json:"enabled"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 256)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "expected a JSON body with enabled")
		return
	}
	if err := s.store.SetFindable(body.Enabled); err != nil {
		writeError(w, http.StatusInternalServerError, "could not save the setting")
		return
	}
	// Told to the name service now, not at the next check twelve hours on.
	if s.reannounce != nil {
		s.reannounce()
	}
	writeJSON(w, http.StatusOK, map[string]bool{"enabled": body.Enabled})
}

// handleSetWebName claims or lets go of the chosen address: PUT {"name":
// "hollberg"}, or "" to have none.
func (s *Server) handleSetWebName(w http.ResponseWriter, r *http.Request) {
	if !s.webNamesAvailable() {
		writeError(w, http.StatusNotImplemented, "a web address needs automatic HTTPS to be on")
		return
	}
	var body struct {
		Name string `json:"name"`
		// Code: one the owner of soundstorm.dev gave out for a held name.
		Code string `json:"code"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 512)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "expected a JSON body with name")
		return
	}
	name := strings.ToLower(strings.TrimSpace(body.Name))
	name = strings.TrimSuffix(name, ".soundstorm.dev")
	previous := s.store.WebName()
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()
	if name == "" {
		if previous != "" {
			if err := s.releaseWebName(ctx, previous); err != nil {
				s.log.Warn("let a web address go", "name", previous, "err", err)
			}
		}
		if err := s.store.SetWebName(""); err != nil {
			writeError(w, http.StatusInternalServerError, "could not save it")
			return
		}
		writeJSON(w, http.StatusOK, map[string]string{"name": ""})
		return
	}
	if why := names.NameStatus(name); why != "" {
		writeError(w, http.StatusBadRequest, why)
		return
	}
	url, err := s.claimWebName(ctx, name, previous, strings.TrimSpace(body.Code))
	if err != nil {
		var se *names.StatusError
		if errors.As(err, &se) && se.Status < 500 {
			writeError(w, http.StatusBadRequest, se.Message)
			return
		}
		s.log.Warn("claim a web address", "name", name, "err", err)
		writeError(w, http.StatusBadGateway, "Could not reach SoundStorm's name service just now. Try again in a minute.")
		return
	}
	if err := s.store.SetWebName(name); err != nil {
		writeError(w, http.StatusInternalServerError, "could not save it")
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"name": name, "url": url})
}
