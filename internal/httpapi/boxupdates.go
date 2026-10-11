package httpapi

import (
	"encoding/json"
	"net/http"
	"time"
)

// Updates on a box, from Settings (owner): which version it is on, what is
// waiting, and Update now - where the box otherwise installs only at night,
// between two and five in its own time zone. The caretaker does the work and
// checks the release is signed; this only asks it (caretakerCall), as Switch
// off and Time zone do.
//
//	GET  /api/box/updates        what the box is on and what is waiting
//	POST /api/box/updates/check  look for an update now
//	POST /api/box/updates/now    install the one waiting
//	PUT  /api/box/updates/auto   {auto}: install by itself at night, or wait to be asked

// caretakerStatus is the little of the caretaker's status the page shows.
type caretakerStatus struct {
	Current *struct {
		Version string    `json:"version"`
		Created time.Time `json:"created"`
	} `json:"current"`
	Available *struct {
		Version string    `json:"version"`
		Created time.Time `json:"created"`
		Notes   string    `json:"notes"`
	} `json:"available"`
	State     string     `json:"state"`
	Message   string     `json:"message"`
	LastCheck *time.Time `json:"lastCheck"`
}

func (s *Server) boxUpdates(w http.ResponseWriter, r *http.Request, st caretakerStatus) {
	var settings struct {
		Auto bool `json:"auto"`
	}
	settings.Auto = true
	_, _ = s.caretakerCall(r.Context(), http.MethodGet, "/settings", nil, &settings)
	answer := map[string]any{
		"state": st.State,
		"auto":  settings.Auto,
	}
	if st.Current != nil {
		answer["version"] = st.Current.Version
		if !st.Current.Created.IsZero() {
			answer["installed"] = st.Current.Created
		}
	}
	if st.Available != nil {
		answer["available"] = map[string]any{
			"version": st.Available.Version,
			"notes":   st.Available.Notes,
		}
	}
	if st.Message != "" {
		answer["message"] = st.Message
	}
	if st.LastCheck != nil {
		answer["lastCheck"] = st.LastCheck
	}
	writeJSON(w, http.StatusOK, answer)
}

// GET /api/box/updates
func (s *Server) handleBoxUpdates(w http.ResponseWriter, r *http.Request) {
	var st caretakerStatus
	if code, err := s.caretakerCall(r.Context(), http.MethodGet, "/status", nil, &st); err != nil || code != http.StatusOK {
		writeError(w, http.StatusBadGateway, "The box could not be asked about updates just now.")
		return
	}
	s.boxUpdates(w, r, st)
}

// POST /api/box/updates/check
func (s *Server) handleBoxUpdatesCheck(w http.ResponseWriter, r *http.Request) {
	var st caretakerStatus
	if code, err := s.caretakerCall(r.Context(), http.MethodPost, "/check", nil, &st); err != nil || code != http.StatusOK {
		writeError(w, http.StatusBadGateway, "The box could not look for updates just now. Check its internet connection.")
		return
	}
	s.boxUpdates(w, r, st)
}

// POST /api/box/updates/now
func (s *Server) handleBoxUpdatesNow(w http.ResponseWriter, r *http.Request) {
	var st caretakerStatus
	code, err := s.caretakerCall(r.Context(), http.MethodPost, "/update", nil, &st)
	switch {
	case err == nil && code == http.StatusAccepted:
		writeJSON(w, http.StatusAccepted, map[string]any{"updating": true})
	case code == http.StatusConflict:
		writeError(w, http.StatusConflict, "There is no update waiting, or the box is busy updating or resetting. Look again in a minute.")
	default:
		writeError(w, http.StatusBadGateway, "The box could not be asked to update just now.")
	}
}

// PUT /api/box/updates/auto {auto}
func (s *Server) handleBoxUpdatesAuto(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Auto *bool `json:"auto"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1024)).Decode(&body); err != nil || body.Auto == nil {
		writeError(w, http.StatusBadRequest, "expected auto: true or false")
		return
	}
	var saved struct {
		Auto bool `json:"auto"`
	}
	if code, err := s.caretakerCall(r.Context(), http.MethodPut, "/settings", map[string]bool{"auto": *body.Auto}, &saved); err != nil || code != http.StatusOK {
		writeError(w, http.StatusBadGateway, "The box could not change that just now.")
		return
	}
	writeJSON(w, http.StatusOK, map[string]bool{"auto": saved.Auto})
}
