package library

import (
	"errors"
	"io"
	"os"
	"path/filepath"
)

// Big files can be sent in pieces (httpapi/pieces.go): a browser's single
// request for a 27GB film is all lost when anything drops it, and Firefox
// 157 dropped every large one part way (the owner's report, 2026-10-09). The
// pieces are written into one staging file here, and once all are in, the
// file is filed exactly as an upload in one piece is - by Save and its kin,
// handed a Staged in place of the bytes, so it is moved into place rather
// than copied a second time.

// Staged is an upload already whole in the staging folder, which Save,
// SaveDecided, SaveRouted and SaveWith take as it is.
type Staged struct{ Path string }

// Read is never used: Save recognises a Staged and takes its file.
func (*Staged) Read([]byte) (int, error) { return 0, io.EOF }

// NewPieceFile makes the staging file a piece-by-piece upload is written
// into. ClearStaging sweeps any left at a restart.
func (l *Library) NewPieceFile() (string, error) {
	staging := filepath.Join(l.root, ".uploads")
	if err := os.MkdirAll(staging, 0o777); err != nil {
		return "", err
	}
	f, err := os.CreateTemp(staging, "piece-*")
	if err != nil {
		return "", err
	}
	name := f.Name()
	return name, f.Close()
}

// errNotPieceFile refuses a path that is not one NewPieceFile made.
var errNotPieceFile = errors.New("that upload is not one of the library's")

// WritePiece appends a piece to a piece file made by NewPieceFile, at
// offset (its length so far), with the same disk reserve an upload in one
// piece keeps. It returns how many bytes it wrote; on an error, the file is
// cut back to offset, so the piece can be sent again.
func (l *Library) WritePiece(name string, offset int64, r io.Reader) (int64, error) {
	staging := filepath.Join(l.root, ".uploads")
	if filepath.Dir(name) != staging {
		return 0, errNotPieceFile
	}
	if !l.Room(reserveCheck) {
		return 0, ErrDiskReserve
	}
	f, err := os.OpenFile(name, os.O_WRONLY, 0)
	if err != nil {
		return 0, err
	}
	defer f.Close()
	if _, err := f.Seek(offset, io.SeekStart); err != nil {
		return 0, err
	}
	n, err := io.Copy(&reserveWriter{w: f, dir: staging}, r)
	if err != nil {
		_ = f.Truncate(offset)
		return 0, receiveError(staging, err)
	}
	return n, f.Close()
}
