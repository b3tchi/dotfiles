package x11

import (
	"bytes"
	"encoding/binary"
	"strings"
	"testing"
)

// --- test helpers: crafted setup-response byte blobs ---

type visualSpec struct {
	visualID                     uint32
	class, bitsPerRGB            byte
	colormapEntries              uint16
	redMask, greenMask, blueMask uint32
}

type depthSpec struct {
	depth   byte
	visuals []visualSpec
}

type screenSpec struct {
	root, defaultColormap, whitePixel, blackPixel, currentInputMasks uint32
	widthPx, heightPx, widthMM, heightMM, minMaps, maxMaps           uint16
	rootVisual                                                       uint32
	backingStores, rootDepth                                         byte
	saveUnders                                                       bool
	depths                                                           []depthSpec
}

func le(buf *bytes.Buffer, v any) {
	if err := binary.Write(buf, binary.LittleEndian, v); err != nil {
		panic(err)
	}
}

func encodeVisual(buf *bytes.Buffer, v visualSpec) {
	le(buf, v.visualID)
	le(buf, v.class)
	le(buf, v.bitsPerRGB)
	le(buf, v.colormapEntries)
	le(buf, v.redMask)
	le(buf, v.greenMask)
	le(buf, v.blueMask)
	le(buf, uint32(0)) // unused
}

func encodeDepth(buf *bytes.Buffer, d depthSpec) {
	le(buf, d.depth)
	le(buf, byte(0)) // unused
	le(buf, uint16(len(d.visuals)))
	le(buf, uint32(0)) // unused
	for _, v := range d.visuals {
		encodeVisual(buf, v)
	}
}

func encodeScreen(buf *bytes.Buffer, s screenSpec) {
	le(buf, s.root)
	le(buf, s.defaultColormap)
	le(buf, s.whitePixel)
	le(buf, s.blackPixel)
	le(buf, s.currentInputMasks)
	le(buf, s.widthPx)
	le(buf, s.heightPx)
	le(buf, s.widthMM)
	le(buf, s.heightMM)
	le(buf, s.minMaps)
	le(buf, s.maxMaps)
	le(buf, s.rootVisual)
	le(buf, s.backingStores)
	var saveUnders byte
	if s.saveUnders {
		saveUnders = 1
	}
	le(buf, saveUnders)
	le(buf, s.rootDepth)
	le(buf, byte(len(s.depths)))
	for _, d := range s.depths {
		encodeDepth(buf, d)
	}
}

// buildSuccessResponse builds a full, well-formed Success setup response
// (including the 8-byte header) for the given vendor string and screens.
func buildSuccessResponse(vendor string, screens []screenSpec) []byte {
	var body bytes.Buffer
	le(&body, uint32(0))           // release-number
	le(&body, uint32(0x00800000))  // resource-id-base
	le(&body, uint32(0x001fffff))  // resource-id-mask
	le(&body, uint32(256))         // motion-buffer-size
	le(&body, uint16(len(vendor))) // vendor length
	le(&body, uint16(65535))       // maximum-request-length
	le(&body, byte(len(screens)))  // number of screens
	le(&body, byte(0))             // number of formats
	le(&body, byte(0))             // image-byte-order
	le(&body, byte(0))             // bitmap-format-bit-order
	le(&body, byte(32))            // bitmap-format-scanline-unit
	le(&body, byte(32))            // bitmap-format-scanline-pad
	le(&body, byte(8))             // min-keycode
	le(&body, byte(255))           // max-keycode
	le(&body, uint32(0))           // unused

	body.WriteString(vendor)
	padLen := pad4(len(vendor))
	body.Write(make([]byte, padLen))

	for _, s := range screens {
		encodeScreen(&body, s)
	}

	if body.Len()%4 != 0 {
		panic("test helper produced a non-4-byte-aligned body")
	}

	var out bytes.Buffer
	le(&out, byte(1)) // Success
	le(&out, byte(0)) // unused
	le(&out, uint16(11))
	le(&out, uint16(0))
	le(&out, uint16(body.Len()/4))
	out.Write(body.Bytes())
	return out.Bytes()
}

func buildFailedResponse(reason string) []byte {
	var out bytes.Buffer
	le(&out, byte(0))           // Failed
	le(&out, byte(len(reason))) // reason length
	le(&out, uint16(11))
	le(&out, uint16(0))
	le(&out, uint16(pad4Units(len(reason))))
	out.WriteString(reason)
	out.Write(make([]byte, pad4(len(reason))))
	return out.Bytes()
}

func pad4Units(n int) int {
	return (n + pad4(n)) / 4
}

// --- tests ---

func TestPad4(t *testing.T) {
	cases := []struct {
		n    int
		want int
	}{
		{0, 0}, {1, 3}, {2, 2}, {3, 1}, {4, 0}, {5, 3}, {20, 0}, {21, 3},
	}
	for _, tc := range cases {
		if got := pad4(tc.n); got != tc.want {
			t.Errorf("pad4(%d) = %d, want %d", tc.n, got, tc.want)
		}
	}
}

func TestBuildSetupRequest(t *testing.T) {
	req := BuildSetupRequest("MIT-MAGIC-COOKIE-1", []byte("\xde\xad\xbe\xef"))

	if len(req) < 12 {
		t.Fatalf("request too short: %d bytes", len(req))
	}
	if req[0] != 'l' {
		t.Errorf("byte-order byte = %q, want 'l' (LSBFirst)", req[0])
	}
	major := binary.LittleEndian.Uint16(req[2:4])
	minor := binary.LittleEndian.Uint16(req[4:6])
	if major != 11 || minor != 0 {
		t.Errorf("protocol version = %d.%d, want 11.0", major, minor)
	}
	nameLen := binary.LittleEndian.Uint16(req[6:8])
	dataLen := binary.LittleEndian.Uint16(req[8:10])
	if nameLen != uint16(len("MIT-MAGIC-COOKIE-1")) {
		t.Errorf("nameLen = %d, want %d", nameLen, len("MIT-MAGIC-COOKIE-1"))
	}
	if dataLen != 4 {
		t.Errorf("dataLen = %d, want 4", dataLen)
	}
	if len(req)%4 != 0 {
		t.Errorf("request length %d is not 4-byte aligned", len(req))
	}
}

func TestParseSetupResponse_FailedDecodesReason(t *testing.T) {
	blob := buildFailedResponse("Authorization required, but no authorization protocol specified")

	_, err := ParseSetupResponse(bytes.NewReader(blob))
	if err == nil {
		t.Fatal("expected an error for a Failed setup response, got nil")
	}
	if !strings.Contains(err.Error(), "Authorization required") {
		t.Errorf("error %q does not contain the server's reason string", err.Error())
	}
}

func TestParseSetupResponse_SuccessMinimal(t *testing.T) {
	blob := buildSuccessResponse("The X.Org Foundation", []screenSpec{
		{
			root: 0x37, defaultColormap: 0x20, whitePixel: 0xffffffff, blackPixel: 0,
			currentInputMasks: 0, widthPx: 1920, heightPx: 1080, widthMM: 510, heightMM: 287,
			minMaps: 1, maxMaps: 1, rootVisual: 0x21, backingStores: 0, saveUnders: false,
			rootDepth: 24,
			depths: []depthSpec{
				{depth: 24, visuals: []visualSpec{
					{visualID: 0x21, class: 4, bitsPerRGB: 8, colormapEntries: 256,
						redMask: 0xff0000, greenMask: 0x00ff00, blueMask: 0x0000ff},
				}},
			},
		},
	})

	info, err := ParseSetupResponse(bytes.NewReader(blob))
	if err != nil {
		t.Fatalf("ParseSetupResponse: unexpected error: %v", err)
	}
	if info.Vendor != "The X.Org Foundation" {
		t.Errorf("Vendor = %q, want %q", info.Vendor, "The X.Org Foundation")
	}
	if len(info.Screens) != 1 {
		t.Fatalf("got %d screens, want 1", len(info.Screens))
	}
	sc := info.Screens[0]
	if sc.Root != 0x37 {
		t.Errorf("Root = %#x, want 0x37", sc.Root)
	}
	if sc.WidthInPixels != 1920 || sc.HeightInPixels != 1080 {
		t.Errorf("size = %dx%d, want 1920x1080", sc.WidthInPixels, sc.HeightInPixels)
	}
	if len(sc.Depths) != 1 || len(sc.Depths[0].Visuals) != 1 {
		t.Fatalf("depths/visuals shape wrong: %+v", sc.Depths)
	}
	if sc.Depths[0].Visuals[0].VisualID != 0x21 {
		t.Errorf("VisualID = %#x, want 0x21", sc.Depths[0].Visuals[0].VisualID)
	}
}

func TestParseSetupResponse_VendorLengthNotDivisibleBy4(t *testing.T) {
	// poc015 gotcha 5: "The X.Org Foundation" (20 chars) is invisible to
	// this bug because it IS divisible by 4. Use a vendor string whose
	// length is NOT a multiple of 4 so the pad4 skip after the vendor
	// string is actually exercised -- getting it wrong corrupts every
	// screen that follows.
	vendor := "Custom X Vendor" // 15 chars, 15%4 == 3
	if len(vendor)%4 == 0 {
		t.Fatalf("test fixture bug: vendor length %d IS divisible by 4", len(vendor))
	}

	blob := buildSuccessResponse(vendor, []screenSpec{
		{
			root: 0x99, rootVisual: 0x21, rootDepth: 24,
			widthPx: 800, heightPx: 600,
			depths: []depthSpec{
				{depth: 24, visuals: []visualSpec{
					{visualID: 0x21, class: 4, bitsPerRGB: 8, colormapEntries: 256,
						redMask: 0xff0000, greenMask: 0x00ff00, blueMask: 0x0000ff},
				}},
			},
		},
	})

	info, err := ParseSetupResponse(bytes.NewReader(blob))
	if err != nil {
		t.Fatalf("ParseSetupResponse: unexpected error: %v", err)
	}
	if info.Vendor != vendor {
		t.Errorf("Vendor = %q, want %q", info.Vendor, vendor)
	}
	if len(info.Screens) != 1 || info.Screens[0].Root != 0x99 {
		t.Fatalf("screen data corrupted after odd-length vendor string: %+v", info.Screens)
	}
}

func TestParseSetupResponse_ScreenWalkMismatchIsHardError(t *testing.T) {
	blob := buildSuccessResponse("Vendor", []screenSpec{
		{
			root: 0x1, rootVisual: 0x21, rootDepth: 24,
			depths: []depthSpec{
				{depth: 24, visuals: []visualSpec{
					{visualID: 0x21, class: 4, bitsPerRGB: 8, colormapEntries: 256,
						redMask: 0xff0000, greenMask: 0x00ff00, blueMask: 0x0000ff},
				}},
			},
		},
	})

	// Corrupt the additional-data-length field (the CARD16 at offset 6,
	// after the 1-byte status, 1-byte unused, 2-byte major, 2-byte
	// minor) so the declared body length no longer matches what the
	// screen walk actually consumes.
	corrupted := append([]byte(nil), blob...)
	binary.LittleEndian.PutUint16(corrupted[6:8], binary.LittleEndian.Uint16(corrupted[6:8])+1)
	// Pad the blob so ReadFull for the (now larger) declared length
	// still succeeds -- the mismatch must be caught by the off==len(buf)
	// assertion, not by a short read.
	corrupted = append(corrupted, 0, 0, 0, 0)

	_, err := ParseSetupResponse(bytes.NewReader(corrupted))
	if err == nil {
		t.Fatal("expected a hard error when the screen walk does not land exactly on len(buf)")
	}
}
