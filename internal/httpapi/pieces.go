package httpapi

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"strconv"
	"sync"
	"time"

	"github.com/GabrielHollberg/soundstorm/internal/auth"
	"github.com/GabrielHollberg/soundstorm/internal/library"
	"github.com/GabrielHollberg/soundstorm/internal/source"
)

// Big files are sent in pieces (the owner's report, 2026-10-09): one request
// for a 27GB film is all lost when anything drops it part way - Firefox 157
// dropped every large upload after a few hundred megabytes - and a phone
// changing network loses an hour's film. The page starts an upload, sends
// pieces of up to pieceMax in order, sends a piece again when one fails, and
// asks how far the server has got when unsure; once the last is in, the file
// is filed exactly as an upload in one piece is (addFile), moved into place
// rather than copied again (library.Staged).
//
//	POST   /api/upload/pieces            {path, kind, size, conflict, as, taken} -> {id}
//	PUT    /api/upload/pieces/{id}?offset=N   one piece -> {received} or, the last, {dest}
//	GET    /api/upload/pieces/{id}       -> {received}
//	DELETE /api/upload/pieces/{id}       stopped: the piece file goes
//
// What an upload is lives only in memory: after a restart the page starts it
// again, and ClearStaging sweeps the half-written file.

const (
	// pieceMax is the most one piece may carry; the page sends 8MB.
	pieceMax = 32 << 20
	// piecesPerUser is how many unfinished uploads one account may have.
	piecesPerUser = 8
	// pieceIdle is how long an upload nobody has sent to is kept.
	pieceIdle = 6 * time.Hour
)

type pieceUpload struct {
	mu       sync.Mutex // one piece at a time
	user     string
	req      addRequest
	file     string
	received int64
	last     time.Time
	done     bool
}

type pieceUploads struct {
	mu sync.Mutex
	m  map[string]*pieceUpload
}

// sweepLocked forgets uploads left idle, deleting their files.
func (p *pieceUploads) sweepLocked(now time.Time) {
	for id, u := range p.m {
		if now.Sub(u.last) > pieceIdle {
			_ = os.Remove(u.file)
			delete(p.m, id)
		}
	}
}

func (s *Server) handlePiecesStart(w http.ResponseWriter, r *http.Request) {
	user, _ := auth.FromContext(r.Context())
	var body struct {
		Path     string `json:"path"`
		Kind     string `json:"kind"`
		Size     int64  `json:"size"`
		Conflict string `json:"conflict"`
		As       string `json:"as"`
		Taken    int64  `json:"taken"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&body); err != nil {
		writeError(w, http.StatusBadRequest, "expected the upload's path, kind and size")
		return
	}
	if body.Path == "" || body.Size <= 0 {
		writeError(w, http.StatusBadRequest, "path and size are required")
		return
	}
	kind, err := s.uploadKind(r, body.Kind)
	if err != nil {
		writeError(w, statusForUpload(err), err.Error())
		return
	}
	if kind == "" {
		writeError(w, http.StatusBadRequest, "kind is required")
		return
	}
	if !s.library.Room(body.Size) {
		writeError(w, http.StatusInsufficientStorage, errLibraryFull.Error())
		return
	}
	id, err := pieceID()
	if err != nil {
		writeError(w, http.StatusInternalServerError, "could not start the upload")
		return
	}

	s.pieces.mu.Lock()
	if s.pieces.m == nil {
		s.pieces.m = map[string]*pieceUpload{}
	}
	now := time.Now()
	s.pieces.sweepLocked(now)
	mine := 0
	for _, u := range s.pieces.m {
		if u.user == user.ID {
			mine++
		}
	}
	if mine >= piecesPerUser {
		s.pieces.mu.Unlock()
		writeError(w, http.StatusTooManyRequests, "too many uploads at once; wait for one to finish")
		return
	}
	file, err := s.library.NewPieceFile()
	if err != nil {
		s.pieces.mu.Unlock()
		writeError(w, http.StatusInternalServerError, "could not start the upload")
		return
	}
	s.pieces.m[id] = &pieceUpload{
		user: user.ID,
		req: addRequest{
			User: user, Access: source.AccessFrom(r.Context()), Kind: kind, Path: body.Path,
			Size: body.Size, Taken: body.Taken, Conflict: body.Conflict, As: body.As,
		},
		file: file,
		last: now,
	}
	s.pieces.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "pieceSize": 8 << 20})
}

// pieceFor finds an upload of the person asking.
func (s *Server) pieceFor(r *http.Request) (*pieceUpload, string, bool) {
	user, _ := auth.FromContext(r.Context())
	id := r.PathValue("id")
	s.pieces.mu.Lock()
	defer s.pieces.mu.Unlock()
	u, ok := s.pieces.m[id]
	if !ok || u.user != user.ID {
		return nil, id, false
	}
	return u, id, true
}

func (s *Server) handlePiecesStatus(w http.ResponseWriter, r *http.Request) {
	u, _, ok := s.pieceFor(r)
	if !ok {
		writeError(w, http.StatusNotFound, "that upload is not here; start it again")
		return
	}
	u.mu.Lock()
	received := u.received
	u.mu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"received": received})
}

func (s *Server) handlePiecesCancel(w http.ResponseWriter, r *http.Request) {
	u, id, ok := s.pieceFor(r)
	if !ok {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	s.pieces.mu.Lock()
	delete(s.pieces.m, id)
	s.pieces.mu.Unlock()
	u.mu.Lock()
	if !u.done {
		_ = os.Remove(u.file)
	}
	u.mu.Unlock()
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handlePiece(w http.ResponseWriter, r *http.Request) {
	u, id, ok := s.pieceFor(r)
	if !ok {
		writeError(w, http.StatusNotFound, "that upload is not here; start it again")
		return
	}
	if !u.mu.TryLock() {
		// Busy, not a refusal: the page waits and asks where it got to.
		writeError(w, http.StatusServiceUnavailable, "a piece of this upload is already arriving")
		return
	}
	defer u.mu.Unlock()
	if u.done {
		writeError(w, http.StatusConflict, "that upload is finished")
		return
	}
	offset, err := strconv.ParseInt(r.URL.Query().Get("offset"), 10, 64)
	if err != nil || offset != u.received {
		// Out of step - a piece sent twice, or one lost: say where it is.
		writeJSON(w, http.StatusConflict, map[string]any{"error": "out of step", "received": u.received})
		return
	}
	if r.ContentLength <= 0 || r.ContentLength > pieceMax || offset+r.ContentLength > u.req.Size {
		writeError(w, http.StatusBadRequest, "that piece is the wrong size")
		return
	}
	release, okSlot := s.takeUploadSlot(u.user)
	if !okSlot {
		writeError(w, http.StatusTooManyRequests, "too many uploads at once; wait for one to finish")
		return
	}
	defer release()

	body := &stallReader{r: http.MaxBytesReader(w, r.Body, r.ContentLength), rc: http.NewResponseController(w)}
	n, err := s.library.WritePiece(u.file, offset, body)
	if err != nil || n != r.ContentLength {
		if err == nil {
			err = errors.New("the piece arrived short")
		}
		if errors.Is(err, library.ErrDiskReserve) {
			writeError(w, http.StatusInsufficientStorage, err.Error())
			return
		}
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": desensitizeFSError(err), "received": u.received})
		return
	}
	u.received += n
	u.last = time.Now()
	if u.received < u.req.Size {
		writeJSON(w, http.StatusOK, map[string]any{"received": u.received})
		return
	}

	// The last piece: filed as any upload is, from the file as it stands.
	u.done = true
	s.pieces.mu.Lock()
	delete(s.pieces.m, id)
	s.pieces.mu.Unlock()
	dest, err := s.addFile(u.req, &library.Staged{Path: u.file})
	_ = os.Remove(u.file) // gone already once filed; refused, nothing keeps it
	if err != nil {
		writeAddError(w, err, u.req.Path)
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"dest": dest, "received": u.received})
}

func pieceID() (string, error) {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}
