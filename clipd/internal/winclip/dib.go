package winclip

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"math/bits"
)

// MaxPixels bounds a DIB before any pixel buffer is allocated (64 Mpx —
// e.g. 8192×8192). Anything bigger is skipped like an over-cap payload.
const MaxPixels = 1 << 26

var ErrDIB = errors.New("winclip: unsupported or malformed DIB")

const (
	biRGB            = 0
	biBitfields      = 3
	biAlphaBitfields = 6
)

// DIBToPNG converts a CF_DIB / CF_DIBV5 payload (BITMAPINFOHEADER or
// BITMAPV5HEADER, then pixels) to PNG. Supported: 24 bpp BI_RGB and
// 32 bpp BI_RGB / BI_BITFIELDS. 32 bpp BI_RGB whose alpha bytes are all 0
// is treated as opaque (the usual GDI convention). The PNG is refused with
// ErrTooLarge if it exceeds cap bytes.
func DIBToPNG(dib []byte, cap int) ([]byte, error) {
	if len(dib) < 40 {
		return nil, ErrDIB
	}
	le := binary.LittleEndian
	hsize := int(le.Uint32(dib[0:]))
	w := int(int32(le.Uint32(dib[4:])))
	h := int(int32(le.Uint32(dib[8:])))
	bpp := int(le.Uint16(dib[14:]))
	comp := le.Uint32(dib[16:])
	clrUsed := int(le.Uint32(dib[32:]))
	if hsize < 40 || hsize > len(dib) || w <= 0 || h == 0 {
		return nil, ErrDIB
	}
	topDown := h < 0
	if topDown {
		h = -h
	}
	if uint64(w)*uint64(h) > MaxPixels {
		return nil, fmt.Errorf("%w: %dx%d DIB", ErrTooLarge, w, h)
	}

	masks := [4]uint32{0x00ff0000, 0x0000ff00, 0x000000ff, 0}
	off := hsize
	switch {
	case comp == biRGB && (bpp == 24 || bpp == 32):
	case (comp == biBitfields || comp == biAlphaBitfields) && bpp == 32:
		n := 3
		if comp == biAlphaBitfields {
			n = 4
		}
		src := dib[40:]
		if hsize == 40 { // masks follow the header
			if len(dib) < 40+4*n {
				return nil, ErrDIB
			}
			off += 4 * n
		} else if hsize < 40+4*n {
			return nil, ErrDIB
		}
		for i := 0; i < n; i++ {
			masks[i] = le.Uint32(src[4*i:])
		}
		if hsize >= 56 && n == 3 {
			masks[3] = le.Uint32(dib[52:]) // V4/V5 alpha mask
		}
	default:
		return nil, fmt.Errorf("%w: %d bpp, compression %d", ErrDIB, bpp, comp)
	}
	if clrUsed < 0 || clrUsed > 256 {
		return nil, ErrDIB
	}
	off += 4 * clrUsed // optional optimisation palette, legal at 24/32 bpp
	stride := (w*bpp + 31) / 32 * 4
	if uint64(off)+uint64(stride)*uint64(h) > uint64(len(dib)) {
		return nil, ErrDIB
	}
	px := dib[off:]

	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	anyAlpha := false
	for y := 0; y < h; y++ {
		row := px[y*stride:]
		dy := h - 1 - y
		if topDown {
			dy = y
		}
		for x := 0; x < w; x++ {
			var c color.NRGBA
			if bpp == 24 {
				p := row[3*x:]
				c = color.NRGBA{p[2], p[1], p[0], 255}
			} else {
				v := le.Uint32(row[4*x:])
				c = color.NRGBA{chan8(v, masks[0]), chan8(v, masks[1]), chan8(v, masks[2]), 255}
				if masks[3] != 0 {
					c.A = chan8(v, masks[3])
				} else if masks[0]|masks[1]|masks[2] == 0x00ffffff {
					// BI_RGB, or bitfields leaving the top byte unmasked:
					// alpha by convention, honoured only if any is non-zero.
					c.A = byte(v >> 24)
				}
				if c.A != 0 {
					anyAlpha = true
				}
			}
			img.SetNRGBA(x, dy, c)
		}
	}
	if bpp == 32 && !anyAlpha {
		for i := 3; i < len(img.Pix); i += 4 {
			img.Pix[i] = 255
		}
	}
	var buf bytes.Buffer
	if err := png.Encode(&buf, img); err != nil {
		return nil, err
	}
	if buf.Len() > cap {
		return nil, fmt.Errorf("%w: %d > %d bytes", ErrTooLarge, buf.Len(), cap)
	}
	return buf.Bytes(), nil
}

// chan8 extracts the channel under mask, scaled to 8 bits.
func chan8(v, mask uint32) byte {
	if mask == 0 {
		return 0
	}
	shift := bits.TrailingZeros32(mask)
	width := bits.OnesCount32(mask)
	c := (v & mask) >> shift
	switch {
	case width == 8:
		return byte(c)
	case width > 8:
		return byte(c >> (width - 8))
	default:
		return byte(c * 255 / (1<<width - 1))
	}
}

// PNGToDIB decodes a PNG and returns a CF_DIB payload: BITMAPINFOHEADER,
// 32 bpp BI_RGB, bottom-up, BGRA. Published next to the registered "PNG"
// format so apps that only read CF_DIB still paste the picked image.
func PNGToDIB(p []byte) ([]byte, error) {
	cfg, err := png.DecodeConfig(bytes.NewReader(p))
	if err != nil {
		return nil, fmt.Errorf("winclip: not a PNG")
	}
	if cfg.Width <= 0 || cfg.Height <= 0 || uint64(cfg.Width)*uint64(cfg.Height) > MaxPixels {
		return nil, fmt.Errorf("%w: %dx%d PNG", ErrTooLarge, cfg.Width, cfg.Height)
	}
	img, err := png.Decode(bytes.NewReader(p))
	if err != nil {
		return nil, fmt.Errorf("winclip: not a PNG")
	}
	b := img.Bounds()
	w, h := b.Dx(), b.Dy()
	out := make([]byte, 40+4*w*h)
	le := binary.LittleEndian
	le.PutUint32(out[0:], 40)
	le.PutUint32(out[4:], uint32(int32(w)))
	le.PutUint32(out[8:], uint32(int32(h))) // positive = bottom-up
	le.PutUint16(out[12:], 1)
	le.PutUint16(out[14:], 32)
	le.PutUint32(out[16:], biRGB)
	le.PutUint32(out[20:], uint32(4*w*h))
	px := out[40:]
	for y := 0; y < h; y++ {
		row := px[(h-1-y)*4*w:]
		for x := 0; x < w; x++ {
			c := color.NRGBAModel.Convert(img.At(b.Min.X+x, b.Min.Y+y)).(color.NRGBA)
			row[4*x], row[4*x+1], row[4*x+2], row[4*x+3] = c.B, c.G, c.R, c.A
		}
	}
	return out, nil
}
