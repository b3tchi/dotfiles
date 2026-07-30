package x11

import (
	"encoding/binary"
	"fmt"
	"io"
)

// pad4 returns the number of padding bytes needed to round n up to a
// multiple of 4, per the X11 wire protocol's alignment rule. Getting this
// wrong on the vendor string is invisible against vendor strings whose
// length already happens to be a multiple of 4 (poc015 gotcha 5) and
// corrupts every screen parsed after it.
func pad4(n int) int {
	return (4 - n%4) % 4
}

// BuildSetupRequest builds the client's X11 connection-setup request: byte
// order 'l' (LSBFirst -- this package parses everything little-endian),
// protocol 11.0, and the given auth protocol name/data, each padded to a
// multiple of 4 bytes.
func BuildSetupRequest(authName string, authData []byte) []byte {
	nameLen := len(authName)
	dataLen := len(authData)

	total := 12 + nameLen + pad4(nameLen) + dataLen + pad4(dataLen)
	buf := make([]byte, total)

	buf[0] = 'l'                                              // LSBFirst
	buf[1] = 0                                                // unused
	binary.LittleEndian.PutUint16(buf[2:4], 11)               // major
	binary.LittleEndian.PutUint16(buf[4:6], 0)                // minor
	binary.LittleEndian.PutUint16(buf[6:8], uint16(nameLen))  // auth name length
	binary.LittleEndian.PutUint16(buf[8:10], uint16(dataLen)) // auth data length
	// buf[10:12] unused

	off := 12
	copy(buf[off:], authName)
	off += nameLen + pad4(nameLen)
	copy(buf[off:], authData)
	off += dataLen + pad4(dataLen)

	return buf
}

// PixmapFormat is one entry of the setup response's pixmap-format list.
type PixmapFormat struct {
	Depth        byte
	BitsPerPixel byte
	ScanlinePad  byte
}

// VisualType describes one visual a screen depth supports.
type VisualType struct {
	VisualID        uint32
	Class           byte
	BitsPerRGBValue byte
	ColormapEntries uint16
	RedMask         uint32
	GreenMask       uint32
	BlueMask        uint32
}

// Depth is one allowed-depth entry of a screen, carrying its visuals.
type Depth struct {
	Depth   byte
	Visuals []VisualType
}

// Screen is one root window / display the server offers, exactly as laid
// out on the wire.
type Screen struct {
	Root                uint32
	DefaultColormap     uint32
	WhitePixel          uint32
	BlackPixel          uint32
	CurrentInputMasks   uint32
	WidthInPixels       uint16
	HeightInPixels      uint16
	WidthInMillimeters  uint16
	HeightInMillimeters uint16
	MinInstalledMaps    uint16
	MaxInstalledMaps    uint16
	RootVisual          uint32
	BackingStores       byte
	SaveUnders          bool
	RootDepth           byte
	Depths              []Depth
}

// SetupInfo is the parsed Success response of the connection setup
// handshake.
type SetupInfo struct {
	ProtocolMajor            uint16
	ProtocolMinor            uint16
	ReleaseNumber            uint32
	ResourceIDBase           uint32
	ResourceIDMask           uint32
	MotionBufferSize         uint32
	MaximumRequestLength     uint16
	ImageByteOrder           byte
	BitmapFormatBitOrder     byte
	BitmapFormatScanlineUnit byte
	BitmapFormatScanlinePad  byte
	MinKeycode               byte
	MaxKeycode               byte
	Vendor                   string
	Formats                  []PixmapFormat
	Screens                  []Screen
}

// ErrSetupFailed is returned when the server's setup response has
// status==0 (Failed). Reason is the server's own explanation (e.g. "no
// authorization protocol specified" for a withheld cookie) -- decoded and
// returned rather than left to hang (poc015: "the status==0 Failed path
// decodes the reason rather than hanging").
type ErrSetupFailed struct {
	Reason string
}

func (e *ErrSetupFailed) Error() string {
	return fmt.Sprintf("x11: setup failed: %s", e.Reason)
}

// ErrSetupAuthenticate is returned for status==2 (Authenticate), the
// further-authentication-required handshake step. This client does not
// implement it; the error names the server's reason text.
type ErrSetupAuthenticate struct {
	Reason string
}

func (e *ErrSetupAuthenticate) Error() string {
	return fmt.Sprintf("x11: setup requires further authentication (unsupported): %s", e.Reason)
}

// ErrScreenWalkMismatch is a hard error: the variable-length screen/depth/
// visual walk did not land exactly on the end of the declared
// additional-data buffer. This must never be papered over with a guessed
// root window (poc015 gotcha 4).
type ErrScreenWalkMismatch struct {
	Consumed, Declared int
}

func (e *ErrScreenWalkMismatch) Error() string {
	return fmt.Sprintf("x11: setup response screen walk consumed %d bytes but declared length was %d bytes -- refusing to guess a root window", e.Consumed, e.Declared)
}

// ParseSetupResponse reads and decodes a server's connection-setup
// response from r, dispatching on the leading status byte.
func ParseSetupResponse(r io.Reader) (*SetupInfo, error) {
	var header [8]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, fmt.Errorf("x11: reading setup response header: %w", err)
	}

	status := header[0]
	major := binary.LittleEndian.Uint16(header[2:4])
	minor := binary.LittleEndian.Uint16(header[4:6])

	switch status {
	case 0: // Failed
		reasonLen := int(header[1])
		lengthUnits := binary.LittleEndian.Uint16(header[6:8])
		body := make([]byte, int(lengthUnits)*4)
		if _, err := io.ReadFull(r, body); err != nil {
			return nil, fmt.Errorf("x11: reading Failed setup reason: %w", err)
		}
		if reasonLen > len(body) {
			reasonLen = len(body)
		}
		return nil, &ErrSetupFailed{Reason: string(body[:reasonLen])}

	case 2: // Authenticate
		lengthUnits := binary.LittleEndian.Uint16(header[6:8])
		body := make([]byte, int(lengthUnits)*4)
		if _, err := io.ReadFull(r, body); err != nil {
			return nil, fmt.Errorf("x11: reading Authenticate setup reason: %w", err)
		}
		return nil, &ErrSetupAuthenticate{Reason: string(body)}

	case 1: // Success
		lengthUnits := binary.LittleEndian.Uint16(header[6:8])
		body := make([]byte, int(lengthUnits)*4)
		if _, err := io.ReadFull(r, body); err != nil {
			return nil, fmt.Errorf("x11: reading Success setup body: %w", err)
		}
		return parseSuccessBody(major, minor, body)

	default:
		return nil, fmt.Errorf("x11: setup response has unknown status byte %d", status)
	}
}

// parseSuccessBody walks the Success response's "additional data" -- the
// fixed fields, the padded vendor string, the pixmap format list, then the
// variable-length screen list -- verifying by arrival that the walk lands
// exactly on len(buf) (poc015 gotcha 4).
func parseSuccessBody(major, minor uint16, buf []byte) (*SetupInfo, error) {
	const fixedLen = 32
	if len(buf) < fixedLen {
		return nil, fmt.Errorf("x11: setup Success body too short: %d bytes", len(buf))
	}

	info := &SetupInfo{ProtocolMajor: major, ProtocolMinor: minor}
	off := 0

	info.ReleaseNumber = binary.LittleEndian.Uint32(buf[off:])
	off += 4
	info.ResourceIDBase = binary.LittleEndian.Uint32(buf[off:])
	off += 4
	info.ResourceIDMask = binary.LittleEndian.Uint32(buf[off:])
	off += 4
	info.MotionBufferSize = binary.LittleEndian.Uint32(buf[off:])
	off += 4
	vendorLen := int(binary.LittleEndian.Uint16(buf[off:]))
	off += 2
	info.MaximumRequestLength = binary.LittleEndian.Uint16(buf[off:])
	off += 2
	numScreens := int(buf[off])
	off++
	numFormats := int(buf[off])
	off++
	info.ImageByteOrder = buf[off]
	off++
	info.BitmapFormatBitOrder = buf[off]
	off++
	info.BitmapFormatScanlineUnit = buf[off]
	off++
	info.BitmapFormatScanlinePad = buf[off]
	off++
	info.MinKeycode = buf[off]
	off++
	info.MaxKeycode = buf[off]
	off++
	off += 4 // unused

	if off+vendorLen > len(buf) {
		return nil, fmt.Errorf("x11: setup response vendor string (%d bytes) overruns body", vendorLen)
	}
	info.Vendor = string(buf[off : off+vendorLen])
	off += vendorLen
	off += pad4(vendorLen) // gotcha 5: vendor is padded to 4 bytes BEFORE the format list

	for i := 0; i < numFormats; i++ {
		if off+8 > len(buf) {
			return nil, fmt.Errorf("x11: setup response pixmap format %d overruns body", i)
		}
		info.Formats = append(info.Formats, PixmapFormat{
			Depth:        buf[off],
			BitsPerPixel: buf[off+1],
			ScanlinePad:  buf[off+2],
		})
		off += 8 // depth, bits-per-pixel, scanline-pad, 5 unused
	}

	for i := 0; i < numScreens; i++ {
		screen, n, err := parseScreen(buf[off:])
		if err != nil {
			return nil, fmt.Errorf("x11: setup response screen %d: %w", i, err)
		}
		info.Screens = append(info.Screens, screen)
		off += n
	}

	if off != len(buf) {
		return nil, &ErrScreenWalkMismatch{Consumed: off, Declared: len(buf)}
	}

	return info, nil
}

// parseScreen decodes one SCREEN structure from the front of buf and
// returns how many bytes it consumed.
func parseScreen(buf []byte) (Screen, int, error) {
	const fixedLen = 40
	if len(buf) < fixedLen {
		return Screen{}, 0, fmt.Errorf("screen fixed fields overrun body: have %d bytes, need %d", len(buf), fixedLen)
	}

	var s Screen
	off := 0
	s.Root = binary.LittleEndian.Uint32(buf[off:])
	off += 4
	s.DefaultColormap = binary.LittleEndian.Uint32(buf[off:])
	off += 4
	s.WhitePixel = binary.LittleEndian.Uint32(buf[off:])
	off += 4
	s.BlackPixel = binary.LittleEndian.Uint32(buf[off:])
	off += 4
	s.CurrentInputMasks = binary.LittleEndian.Uint32(buf[off:])
	off += 4
	s.WidthInPixels = binary.LittleEndian.Uint16(buf[off:])
	off += 2
	s.HeightInPixels = binary.LittleEndian.Uint16(buf[off:])
	off += 2
	s.WidthInMillimeters = binary.LittleEndian.Uint16(buf[off:])
	off += 2
	s.HeightInMillimeters = binary.LittleEndian.Uint16(buf[off:])
	off += 2
	s.MinInstalledMaps = binary.LittleEndian.Uint16(buf[off:])
	off += 2
	s.MaxInstalledMaps = binary.LittleEndian.Uint16(buf[off:])
	off += 2
	s.RootVisual = binary.LittleEndian.Uint32(buf[off:])
	off += 4
	s.BackingStores = buf[off]
	off++
	s.SaveUnders = buf[off] != 0
	off++
	s.RootDepth = buf[off]
	off++
	numDepths := int(buf[off])
	off++

	for i := 0; i < numDepths; i++ {
		d, n, err := parseDepth(buf[off:])
		if err != nil {
			return Screen{}, 0, fmt.Errorf("depth %d: %w", i, err)
		}
		s.Depths = append(s.Depths, d)
		off += n
	}

	return s, off, nil
}

// parseDepth decodes one DEPTH structure from the front of buf and returns
// how many bytes it consumed.
func parseDepth(buf []byte) (Depth, int, error) {
	const fixedLen = 8
	if len(buf) < fixedLen {
		return Depth{}, 0, fmt.Errorf("depth fixed fields overrun body: have %d bytes, need %d", len(buf), fixedLen)
	}

	var d Depth
	off := 0
	d.Depth = buf[off]
	off++
	off++ // unused
	numVisuals := int(binary.LittleEndian.Uint16(buf[off:]))
	off += 2
	off += 4 // unused

	const visualLen = 24
	for i := 0; i < numVisuals; i++ {
		if off+visualLen > len(buf) {
			return Depth{}, 0, fmt.Errorf("visual %d overruns body: have %d bytes remaining, need %d", i, len(buf)-off, visualLen)
		}
		vbuf := buf[off : off+visualLen]
		d.Visuals = append(d.Visuals, VisualType{
			VisualID:        binary.LittleEndian.Uint32(vbuf[0:]),
			Class:           vbuf[4],
			BitsPerRGBValue: vbuf[5],
			ColormapEntries: binary.LittleEndian.Uint16(vbuf[6:]),
			RedMask:         binary.LittleEndian.Uint32(vbuf[8:]),
			GreenMask:       binary.LittleEndian.Uint32(vbuf[12:]),
			BlueMask:        binary.LittleEndian.Uint32(vbuf[16:]),
		})
		off += visualLen
	}

	return d, off, nil
}
