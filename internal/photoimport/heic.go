package photoimport

import (
	"bytes"
	"encoding/binary"
	"io"
	"os"
	"time"
)

// A HEIC (an iPhone's photo, and AVIF alike) keeps its EXIF as an item of
// its own, stored wherever the file's item locations say - not necessarily
// in the first bytes ExifTaken is given. The file's index (the meta box, at
// its start) says where: iinf names the item whose type is "Exif", and iloc
// gives its offset and length. That is all read here: a few small reads,
// never the whole file.

// maxExifItem is the most of an Exif item read: far beyond a camera's.
const maxExifItem = 1 << 20

// ReadTaken is when a photo was taken from the date inside it: from the
// first bytes (head) when it is there, as in a JPEG, else - for a HEIC or
// AVIF - from its Exif item wherever it is stored, read through r.
func ReadTaken(r io.ReaderAt, size int64, head []byte) (time.Time, bool) {
	if t, ok := ExifTaken(head); ok {
		return t, true
	}
	if !isHEIF(head) {
		return time.Time{}, false
	}
	data := heifExif(r, size)
	if data == nil {
		return time.Time{}, false
	}
	return ExifTaken(data)
}

// FileTaken is ReadTaken for a file on disk, whose first bytes have been read.
func FileTaken(path string, head []byte) (time.Time, bool) {
	if t, ok := ExifTaken(head); ok {
		return t, true
	}
	if !isHEIF(head) {
		return time.Time{}, false
	}
	f, err := os.Open(path)
	if err != nil {
		return time.Time{}, false
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return time.Time{}, false
	}
	return ReadTaken(f, st.Size(), head)
}

// isHEIF is whether a file starts as an image in the HEIF family.
func isHEIF(head []byte) bool {
	if len(head) < 12 || string(head[4:8]) != "ftyp" {
		return false
	}
	brands := head[8:min(len(head), 8+int(binary.BigEndian.Uint32(head[0:4])))]
	for _, b := range []string{"heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1", "avif", "avis"} {
		if bytes.Contains(brands, []byte(b)) {
			return true
		}
	}
	return false
}

// heifExif is the Exif item's bytes, or nil.
func heifExif(r io.ReaderAt, size int64) []byte {
	meta := findBox(r, 0, size, "meta")
	if meta == nil {
		return nil
	}
	// meta is a full box: four bytes of version and flags before its children.
	start, end := meta[0]+4, meta[1]
	iinf := findBox(r, start, end, "iinf")
	iloc := findBox(r, start, end, "iloc")
	if iinf == nil || iloc == nil {
		return nil
	}
	id, ok := exifItemID(r, iinf[0], iinf[1])
	if !ok {
		return nil
	}
	off, length, ok := itemExtent(r, iloc[0], iloc[1], id)
	if !ok || length <= 0 || length > maxExifItem || off < 0 || off+length > size {
		return nil
	}
	data := make([]byte, length)
	if _, err := r.ReadAt(data, off); err != nil {
		return nil
	}
	return data
}

// findBox finds a box of a type among the boxes between start and end, and
// answers where its payload starts and ends.
func findBox(r io.ReaderAt, start, end int64, typ string) []int64 {
	hdr := make([]byte, 16)
	for at, n := start, 0; at+8 <= end && n < 4096; n++ {
		if _, err := r.ReadAt(hdr[:8], at); err != nil {
			return nil
		}
		size := int64(binary.BigEndian.Uint32(hdr[:4]))
		head := int64(8)
		switch size {
		case 1:
			if _, err := r.ReadAt(hdr[8:16], at+8); err != nil {
				return nil
			}
			size, head = int64(binary.BigEndian.Uint64(hdr[8:16])), 16
		case 0:
			size = end - at
		}
		if size < head || at+size > end {
			return nil
		}
		if string(hdr[4:8]) == typ {
			return []int64{at + head, at + size}
		}
		at += size
	}
	return nil
}

// readAt reads n bytes at off, or nil.
func readAt(r io.ReaderAt, off int64, n int) []byte {
	if n <= 0 || n > 1<<20 {
		return nil
	}
	b := make([]byte, n)
	if _, err := r.ReadAt(b, off); err != nil {
		return nil
	}
	return b
}

// exifItemID reads iinf (a full box) for the item whose type is "Exif".
func exifItemID(r io.ReaderAt, start, end int64) (uint32, bool) {
	vf := readAt(r, start, 4)
	if vf == nil {
		return 0, false
	}
	at := start + 4
	if vf[0] == 0 {
		at += 2 // entry_count, 16 bits
	} else {
		at += 4 // entry_count, 32 bits
	}
	for n := 0; at+8 <= end && n < 4096; n++ {
		h := readAt(r, at, 8)
		if h == nil {
			return 0, false
		}
		size := int64(binary.BigEndian.Uint32(h[:4]))
		if size < 8 || at+size > end {
			return 0, false
		}
		if string(h[4:8]) == "infe" {
			body := readAt(r, at+8, int(min(size-8, 64)))
			// version 2 (16-bit item id) or 3 (32-bit), then a 16-bit
			// protection index, then the item's type.
			if body != nil && len(body) >= 4 {
				var id uint32
				var typAt int
				switch body[0] {
				case 2:
					if len(body) >= 12 {
						id, typAt = uint32(binary.BigEndian.Uint16(body[4:6])), 8
					}
				case 3:
					if len(body) >= 14 {
						id, typAt = binary.BigEndian.Uint32(body[4:8]), 10
					}
				}
				if typAt > 0 && string(body[typAt:typAt+4]) == "Exif" {
					return id, true
				}
			}
		}
		at += size
	}
	return 0, false
}

// itemExtent reads iloc (a full box) for where an item's first extent is.
func itemExtent(r io.ReaderAt, start, end int64, want uint32) (int64, int64, bool) {
	b := readAt(r, start, int(min(end-start, 1<<16)))
	if len(b) < 8 {
		return 0, 0, false
	}
	version := b[0]
	offSize, lenSize := int(b[4]>>4), int(b[4]&0xF)
	baseSize, idxSize := int(b[5]>>4), int(b[5]&0xF)
	p := 6
	num := func(n int) (uint64, bool) {
		if n == 0 {
			return 0, true
		}
		if p+n > len(b) {
			return 0, false
		}
		var v uint64
		for i := 0; i < n; i++ {
			v = v<<8 | uint64(b[p+i])
		}
		p += n
		return v, true
	}
	var count uint64
	var ok bool
	if version < 2 {
		count, ok = num(2)
	} else {
		count, ok = num(4)
	}
	if !ok {
		return 0, 0, false
	}
	for i := uint64(0); i < count && i < 4096; i++ {
		var id uint64
		if version < 2 {
			id, ok = num(2)
		} else {
			id, ok = num(4)
		}
		if !ok {
			return 0, 0, false
		}
		method := uint64(0)
		if version == 1 || version == 2 {
			if method, ok = num(2); !ok {
				return 0, 0, false
			}
			method &= 0xF
		}
		if _, ok = num(2); !ok { // data reference index
			return 0, 0, false
		}
		base, ok := num(baseSize)
		if !ok {
			return 0, 0, false
		}
		extents, ok := num(2)
		if !ok {
			return 0, 0, false
		}
		var firstOff, firstLen uint64
		for e := uint64(0); e < extents && e < 4096; e++ {
			if (version == 1 || version == 2) && idxSize > 0 {
				if _, ok = num(idxSize); !ok {
					return 0, 0, false
				}
			}
			o, ok1 := num(offSize)
			l, ok2 := num(lenSize)
			if !ok1 || !ok2 {
				return 0, 0, false
			}
			if e == 0 {
				firstOff, firstLen = o, l
			}
		}
		if uint32(id) == want {
			// Only an item stored in the file itself (method 0) is read.
			if method != 0 {
				return 0, 0, false
			}
			return int64(base + firstOff), int64(firstLen), true
		}
	}
	return 0, 0, false
}
