package photoimport

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// exifBlock is an Exif item's payload: the 4-byte offset HEIF puts first,
// then "Exif\0\0" and a TIFF holding DateTimeOriginal.
func exifBlock(date string) []byte {
	le := binary.LittleEndian
	tiff := []byte{'I', 'I', 42, 0}
	tiff = le.AppendUint32(tiff, 8)
	tiff = le.AppendUint16(tiff, 1)
	tiff = le.AppendUint16(tiff, 0x8769)
	tiff = le.AppendUint16(tiff, 4)
	tiff = le.AppendUint32(tiff, 1)
	tiff = le.AppendUint32(tiff, 26)
	tiff = le.AppendUint32(tiff, 0)
	tiff = le.AppendUint16(tiff, 1)
	tiff = le.AppendUint16(tiff, 0x9003)
	tiff = le.AppendUint16(tiff, 2)
	tiff = le.AppendUint32(tiff, 20)
	tiff = le.AppendUint32(tiff, 44)
	tiff = le.AppendUint32(tiff, 0)
	tiff = append(tiff, []byte(date+"\x00")...)
	return append([]byte{0, 0, 0, 6, 'E', 'x', 'i', 'f', 0, 0}, tiff...)
}

func box(typ string, payload ...[]byte) []byte {
	body := bytes.Join(payload, nil)
	out := binary.BigEndian.AppendUint32(nil, uint32(8+len(body)))
	return append(append(out, typ...), body...)
}

// heifWithLateExif builds a HEIC whose Exif item is stored far past its first
// bytes, as an iPhone may: ftyp, meta (iinf naming item 2 "Exif", iloc giving
// its place), a large mdat, then the Exif item.
func heifWithLateExif(date string, gap int) []byte {
	be := binary.BigEndian
	ftyp := box("ftyp", []byte("heic"), []byte{0, 0, 0, 0}, []byte("mif1heic"))
	infe := func(id uint16, typ string) []byte {
		p := []byte{2, 0, 0, 0}
		p = be.AppendUint16(p, id)
		p = be.AppendUint16(p, 0)
		return box("infe", p, []byte(typ), []byte{0})
	}
	iinf := box("iinf", []byte{0, 0, 0, 0}, be.AppendUint16(nil, 2), infe(1, "hvc1"), infe(2, "Exif"))
	exif := exifBlock(date)
	// iloc v0: offset and length 4 bytes, no base; filled in once the
	// Exif item's place is known.
	iloc := func(off uint32) []byte {
		p := []byte{0, 0, 0, 0, 0x44, 0x00}
		p = be.AppendUint16(p, 1)   // one item
		p = be.AppendUint16(p, 2)   // item 2
		p = be.AppendUint16(p, 0)   // data reference
		p = be.AppendUint16(p, 1)   // one extent
		p = be.AppendUint32(p, off) // where
		p = be.AppendUint32(p, uint32(len(exif)))
		return box("iloc", p)
	}
	meta := func(off uint32) []byte { return box("meta", []byte{0, 0, 0, 0}, iinf, iloc(off)) }
	mdat := box("mdat", make([]byte, gap))
	off := uint32(len(ftyp) + len(meta(0)) + len(mdat))
	return bytes.Join([][]byte{ftyp, meta(off), mdat, exif}, nil)
}

// A HEIC's date is found wherever its Exif item is stored, through the
// file's own index - not only when it falls in the first bytes read.
func TestAHEICsDateIsFoundWhereverItIs(t *testing.T) {
	data := heifWithLateExif("2022:11:05 17:45:10", 2<<20)
	path := filepath.Join(t.TempDir(), "IMG_0001.HEIC")
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
	head := data[:512<<10]
	if _, ok := ExifTaken(head); ok {
		t.Fatal("the test file should not have its date in the first bytes")
	}
	got, ok := FileTaken(path, head)
	if !ok || !got.Equal(time.Date(2022, 11, 5, 17, 45, 10, 0, time.UTC)) {
		t.Fatalf("FileTaken = %v, %v", got, ok)
	}
	if got2, ok := ReadTaken(bytes.NewReader(data), int64(len(data)), head); !ok || !got2.Equal(got) {
		t.Errorf("ReadTaken = %v, %v", got2, ok)
	}
	// A JPEG with no date, and a truncated HEIC, give nothing (and do not panic).
	if _, ok := FileTaken(path, []byte("\xff\xd8\xff\xe0 no date")); ok {
		t.Error("a JPEG without a date read as dated")
	}
	short := data[:len(data)/2]
	if _, ok := ReadTaken(bytes.NewReader(short), int64(len(short)), short[:4096]); ok {
		t.Error("a cut-short HEIC read as dated")
	}
}
