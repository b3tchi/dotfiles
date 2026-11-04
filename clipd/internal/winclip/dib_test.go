package winclip

import (
	"bytes"
	"encoding/binary"
	"errors"
	"image"
	"image/color"
	"image/png"
	"testing"
)

// dib builds a BITMAPINFOHEADER DIB; rows are given top-first as BGR(A)
// pixel bytes and laid out bottom-up unless topDown.
func dib(w, h, bpp int, comp uint32, masks []uint32, topDown bool, rows [][]byte) []byte {
	stride := (w*bpp + 31) / 32 * 4
	var b bytes.Buffer
	le := binary.LittleEndian
	hh := int32(h)
	if topDown {
		hh = -hh
	}
	for _, v := range []any{uint32(40), int32(w), hh, uint16(1), uint16(bpp), comp,
		uint32(stride * h), int32(0), int32(0), uint32(0), uint32(0)} {
		binary.Write(&b, le, v)
	}
	for _, m := range masks {
		binary.Write(&b, le, m)
	}
	for i := range rows {
		r := rows[len(rows)-1-i]
		if topDown {
			r = rows[i]
		}
		row := make([]byte, stride)
		copy(row, r)
		b.Write(row)
	}
	return b.Bytes()
}

func decode(t *testing.T, p []byte) image.Image {
	t.Helper()
	img, err := png.Decode(bytes.NewReader(p))
	if err != nil {
		t.Fatal(err)
	}
	return img
}

func px(img image.Image, x, y int) color.NRGBA {
	return color.NRGBAModel.Convert(img.At(x, y)).(color.NRGBA)
}

func TestDIBToPNG24BottomUp(t *testing.T) {
	// 2×2, top row red|green, bottom row blue|white (BGR bytes).
	d := dib(2, 2, 24, biRGB, nil, false, [][]byte{
		{0, 0, 255, 0, 255, 0},
		{255, 0, 0, 255, 255, 255},
	})
	p, err := DIBToPNG(d, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	img := decode(t, p)
	want := map[[2]int]color.NRGBA{
		{0, 0}: {255, 0, 0, 255}, {1, 0}: {0, 255, 0, 255},
		{0, 1}: {0, 0, 255, 255}, {1, 1}: {255, 255, 255, 255},
	}
	for xy, c := range want {
		if got := px(img, xy[0], xy[1]); got != c {
			t.Fatalf("pixel %v = %v, want %v", xy, got, c)
		}
	}
}

func TestDIBToPNG32(t *testing.T) {
	// BI_RGB with all-zero alpha → opaque.
	d := dib(1, 2, 32, biRGB, nil, true, [][]byte{{10, 20, 30, 0}, {40, 50, 60, 0}})
	p, err := DIBToPNG(d, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	img := decode(t, p)
	if got := px(img, 0, 0); got != (color.NRGBA{30, 20, 10, 255}) {
		t.Fatalf("top-down row 0 = %v", got)
	}
	// BI_BITFIELDS with masks after the header, real alpha kept.
	d = dib(1, 1, 32, biBitfields, []uint32{0xff0000, 0xff00, 0xff}, false, [][]byte{{1, 2, 3, 128}})
	p, err = DIBToPNG(d, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if got := px(decode(t, p), 0, 0); got != (color.NRGBA{3, 2, 1, 128}) {
		t.Fatalf("bitfields = %v", got)
	}
}

func TestDIBToPNGRejects(t *testing.T) {
	ok := dib(4, 4, 24, biRGB, nil, false, make([][]byte, 4))
	cases := map[string][]byte{
		"short":     ok[:30],
		"truncated": ok[:len(ok)-1],
		"8bpp":      dib(4, 4, 8, biRGB, nil, false, make([][]byte, 4)),
		"rle":       dib(4, 4, 24, 1, nil, false, make([][]byte, 4)),
	}
	for name, d := range cases {
		if _, err := DIBToPNG(d, 1<<20); !errors.Is(err, ErrDIB) {
			t.Fatalf("%s: %v", name, err)
		}
	}
	if _, err := DIBToPNG(ok, 10); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("over cap: %v", err)
	}
	huge := append([]byte(nil), ok...)
	binary.LittleEndian.PutUint32(huge[4:], 1<<14)
	binary.LittleEndian.PutUint32(huge[8:], 1<<14)
	if _, err := DIBToPNG(huge, 1<<30); !errors.Is(err, ErrTooLarge) {
		t.Fatalf("huge header: %v", err)
	}
}

func TestPNGToDIBRoundTrip(t *testing.T) {
	src := image.NewNRGBA(image.Rect(0, 0, 3, 2))
	src.Set(0, 0, color.NRGBA{255, 0, 0, 255})
	src.Set(2, 1, color.NRGBA{0, 0, 255, 200})
	var b bytes.Buffer
	png.Encode(&b, src)
	d, err := PNGToDIB(b.Bytes())
	if err != nil {
		t.Fatal(err)
	}
	if binary.LittleEndian.Uint32(d[0:]) != 40 || len(d) != 40+4*3*2 {
		t.Fatalf("header/size: %d bytes", len(d))
	}
	p, err := DIBToPNG(d, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	img := decode(t, p)
	if px(img, 0, 0) != (color.NRGBA{255, 0, 0, 255}) || px(img, 2, 1) != (color.NRGBA{0, 0, 255, 200}) {
		t.Fatalf("round trip: %v %v", px(img, 0, 0), px(img, 2, 1))
	}
	if _, err := PNGToDIB([]byte("not a png")); err == nil {
		t.Fatal("garbage accepted")
	}
}
