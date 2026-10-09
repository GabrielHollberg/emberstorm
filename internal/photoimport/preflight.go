package photoimport

import (
	"bufio"
	"encoding/binary"
	"io"
	"os"
)

// maxDirectory is the most of a zip's directory read before it is opened.
// A real download's entry is about a hundred bytes of directory, so 500,000
// of them are some 50MB; archive/zip keeps several hundred bytes in memory
// for each, which is why the count is checked first.
const maxDirectory = 128 << 20

// preflight counts a zip's directory entries the way archive/zip will read
// them, before archive/zip reads them all into memory: a 78MB zip of a
// million empty entries took 849MB to open (the blind security review).
// Neither the zip's own count nor its directory size can be believed -
// archive/zip reads headers from the directory's start until one is not a
// header, checking the count only modulo 65536 (the thirteenth security
// pass) - so the headers are walked, from both places archive/zip may start
// them, and a zip past maxEntries or maxDirectory refused. A zip with no end
// record is left for archive/zip to refuse.
func preflight(zipPath string) error {
	f, err := os.Open(zipPath)
	if err != nil {
		return err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return err
	}
	size := st.Size()
	const endLen = 22
	tail := min(size, int64(endLen+0xFFFF))
	buf := make([]byte, tail)
	if _, err := f.ReadAt(buf, size-tail); err != nil && err != io.EOF {
		return err
	}
	for i := len(buf) - endLen; i >= 0; i-- {
		if binary.LittleEndian.Uint32(buf[i:]) != 0x06054b50 {
			continue
		}
		if i+endLen+int(binary.LittleEndian.Uint16(buf[i+20:])) > len(buf) {
			continue
		}
		endAt := size - tail + int64(i)
		entries := uint64(binary.LittleEndian.Uint16(buf[i+10:]))
		dir := uint64(binary.LittleEndian.Uint32(buf[i+12:]))
		dirOff := uint64(binary.LittleEndian.Uint32(buf[i+16:]))
		// The zip64 record only when archive/zip would read it.
		if entries == 0xFFFF || dir == 0xFFFFFFFF || dirOff == 0xFFFFFFFF {
			if i < 20 || binary.LittleEndian.Uint32(buf[i-20:]) != 0x07064b50 {
				return ErrImplausible
			}
			at := int64(binary.LittleEndian.Uint64(buf[i-20+8:]))
			rec := make([]byte, 56)
			if at < 0 || at+56 > size {
				return ErrImplausible
			}
			if _, err := f.ReadAt(rec, at); err != nil || binary.LittleEndian.Uint32(rec) != 0x06064b50 {
				return ErrImplausible
			}
			endAt = at
			entries = binary.LittleEndian.Uint64(rec[32:])
			dir = binary.LittleEndian.Uint64(rec[40:])
			dirOff = binary.LittleEndian.Uint64(rec[48:])
		}
		if entries > maxEntries || dir > maxDirectory || dir > uint64(size) || dirOff > uint64(size) {
			return ErrImplausible
		}
		// Where archive/zip starts: the offset as written, or moved by what
		// lies before the zip (baseOffset). Both are walked.
		base := endAt - int64(dir) - int64(dirOff)
		for _, start := range []int64{int64(dirOff), int64(dirOff) + base} {
			if start < 0 || start >= size {
				continue
			}
			if n, read := countHeaders(f, start, size); n > maxEntries || read > maxDirectory {
				return ErrImplausible
			}
		}
		return nil
	}
	return nil
}

// countHeaders walks central directory headers from start as archive/zip
// does, until one is not a header, and says how many and how many bytes;
// it stops early once either is past what a download may have.
func countHeaders(f *os.File, start, size int64) (n int, read int64) {
	r := bufio.NewReaderSize(io.NewSectionReader(f, start, size-start), 64<<10)
	head := make([]byte, 46)
	for n <= maxEntries && read <= maxDirectory {
		if _, err := io.ReadFull(r, head); err != nil || binary.LittleEndian.Uint32(head) != 0x02014b50 {
			return n, read
		}
		rest := int(binary.LittleEndian.Uint16(head[28:])) + int(binary.LittleEndian.Uint16(head[30:])) + int(binary.LittleEndian.Uint16(head[32:]))
		if _, err := r.Discard(rest); err != nil {
			return n, read
		}
		n++
		read += int64(46 + rest)
	}
	return n, read
}
