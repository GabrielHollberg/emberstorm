package photoimport

import (
	"encoding/binary"
	"io"
	"os"
)

// maxDirectory is the most of a zip's directory read before it is opened.
// A real download's entry is about a hundred bytes of directory, so 500,000
// of them are some 50MB; archive/zip keeps several hundred bytes in memory
// for each, which is why the count is checked first.
const maxDirectory = 128 << 20

// preflight reads a zip's own count of its entries, and its directory's
// size, from the records at its end - a few bytes - and refuses a zip past
// maxEntries or maxDirectory before archive/zip reads the whole directory
// into memory: a 78MB zip of a million empty entries took 849MB to open
// (the blind security review). A zip with no end record is left for
// archive/zip to refuse.
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
		entries := uint64(binary.LittleEndian.Uint16(buf[i+10:]))
		dir := uint64(binary.LittleEndian.Uint32(buf[i+12:]))
		// A zip64 archive (any download past 4GB) keeps the real figures in
		// its zip64 end record, which the locator just before says where.
		if i >= 20 && binary.LittleEndian.Uint32(buf[i-20:]) == 0x07064b50 {
			at := int64(binary.LittleEndian.Uint64(buf[i-20+8:]))
			rec := make([]byte, 56)
			if at < 0 || at+56 > size {
				return ErrImplausible
			}
			if _, err := f.ReadAt(rec, at); err != nil || binary.LittleEndian.Uint32(rec) != 0x06064b50 {
				return ErrImplausible
			}
			entries = binary.LittleEndian.Uint64(rec[32:])
			dir = binary.LittleEndian.Uint64(rec[40:])
		}
		if entries > maxEntries || dir > maxDirectory {
			return ErrImplausible
		}
		return nil
	}
	return nil
}
