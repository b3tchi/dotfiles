package i3

import (
	"bytes"
	"errors"
	"io"
	"testing"
)

// chunkReader returns at most n bytes per Read call, regardless of how much
// the caller asked for -- it exists to prove readFrame does NOT assume a
// single Read call returns a whole header or a whole payload. A naive
// implementation that reads once and trusts the byte count would silently
// truncate against this reader.
type chunkReader struct {
	buf   []byte
	chunk int
}

func (r *chunkReader) Read(p []byte) (int, error) {
	if len(r.buf) == 0 {
		return 0, io.EOF
	}
	n := r.chunk
	if n > len(p) {
		n = len(p)
	}
	if n > len(r.buf) {
		n = len(r.buf)
	}
	copy(p, r.buf[:n])
	r.buf = r.buf[n:]
	return n, nil
}

func encodeFrame(t *testing.T, mtype uint32, payload []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	if err := writeFrame(&buf, mtype, payload); err != nil {
		t.Fatalf("writeFrame: %v", err)
	}
	return buf.Bytes()
}

func TestWriteFrame_ThenReadFrame_RoundTrip(t *testing.T) {
	var buf bytes.Buffer
	payload := []byte(`{"hello":"world"}`)
	if err := writeFrame(&buf, MsgRunCommand, payload); err != nil {
		t.Fatalf("writeFrame: %v", err)
	}

	// Wire shape check: magic, then LE length, then LE type.
	got := buf.Bytes()
	if string(got[:6]) != Magic {
		t.Fatalf("magic = %q, want %q", got[:6], Magic)
	}

	f, err := readFrame(bytes.NewReader(got))
	if err != nil {
		t.Fatalf("readFrame: %v", err)
	}
	if f.mtype != MsgRunCommand {
		t.Errorf("mtype = %d, want %d", f.mtype, MsgRunCommand)
	}
	if string(f.payload) != string(payload) {
		t.Errorf("payload = %q, want %q", f.payload, payload)
	}
}

func TestReadFrame_EmptyPayload(t *testing.T) {
	var buf bytes.Buffer
	if err := writeFrame(&buf, MsgGetBindingState, nil); err != nil {
		t.Fatalf("writeFrame: %v", err)
	}
	f, err := readFrame(&buf)
	if err != nil {
		t.Fatalf("readFrame: %v", err)
	}
	if len(f.payload) != 0 {
		t.Errorf("payload = %q, want empty", f.payload)
	}
}

func TestReadFrame_TornHeader(t *testing.T) {
	// The header is 14 bytes (6 magic + 4 length + 4 type). A reader that
	// hands back 1 byte at a time forces readFrame through multiple Read
	// calls to assemble it -- io.ReadFull's job, not a single Read.
	raw := encodeFrame(t, MsgSubscribe, []byte(`["mode"]`))
	r := &chunkReader{buf: raw, chunk: 1}

	f, err := readFrame(r)
	if err != nil {
		t.Fatalf("readFrame with torn header: %v", err)
	}
	if f.mtype != MsgSubscribe {
		t.Errorf("mtype = %d, want %d", f.mtype, MsgSubscribe)
	}
	if string(f.payload) != `["mode"]` {
		t.Errorf("payload = %q", f.payload)
	}
}

func TestReadFrame_TornPayload(t *testing.T) {
	// Payload chunked 3 bytes at a time -- the header arrives whole (well
	// within one 3-byte chunk boundary sequence) but the payload spans many
	// short reads.
	payload := []byte(`{"success":true,"error":""}` + `{"success":false,"error":"nope"}`)
	raw := encodeFrame(t, MsgRunCommand, payload)
	r := &chunkReader{buf: raw, chunk: 3}

	f, err := readFrame(r)
	if err != nil {
		t.Fatalf("readFrame with torn payload: %v", err)
	}
	if string(f.payload) != string(payload) {
		t.Errorf("payload = %q, want %q", f.payload, payload)
	}
}

func TestReadFrame_EOFMidHeader(t *testing.T) {
	raw := encodeFrame(t, MsgRunCommand, []byte("x"))
	// Truncate mid-header (only 5 of 14 header bytes survive).
	r := bytes.NewReader(raw[:5])

	_, err := readFrame(r)
	if err == nil {
		t.Fatal("expected an error, got nil")
	}
	if !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed, got %v", err)
	}
}

func TestReadFrame_EOFMidPayload(t *testing.T) {
	raw := encodeFrame(t, MsgRunCommand, []byte("0123456789"))
	// Keep the whole 14-byte header but cut the payload short.
	r := bytes.NewReader(raw[:14+4])

	_, err := readFrame(r)
	if err == nil {
		t.Fatal("expected an error, got nil")
	}
	if !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed, got %v", err)
	}
}

func TestReadFrame_BadMagic(t *testing.T) {
	raw := encodeFrame(t, MsgRunCommand, []byte("x"))
	corrupt := append([]byte(nil), raw...)
	corrupt[0] = 'X'

	_, err := readFrame(bytes.NewReader(corrupt))
	if err == nil {
		t.Fatal("expected an error for bad magic, got nil")
	}
	if errors.Is(err, ErrClosed) {
		t.Fatal("bad magic should not be reported as ErrClosed")
	}
}

func TestReadFrame_CleanEOFBeforeAnyByte(t *testing.T) {
	// A connection that is simply closed with nothing pending must report
	// ErrClosed too (not a bare io.EOF the caller has to know to translate).
	r := bytes.NewReader(nil)
	_, err := readFrame(r)
	if !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed, got %v", err)
	}
}

func TestDiscoverSocket_UsesI3SOCKEnv(t *testing.T) {
	t.Setenv("I3SOCK", "/tmp/example-i3.sock")
	got, err := DiscoverSocket()
	if err != nil {
		t.Fatalf("DiscoverSocket: %v", err)
	}
	if got != "/tmp/example-i3.sock" {
		t.Errorf("got %q, want the I3SOCK value", got)
	}
}
