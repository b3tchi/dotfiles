// Package entry is the plaintext model of one clipd sync-folder entry
// (sp039 plan, "Entry format"): a single JSON object, encrypted as a whole
// by internal/crypt before it touches disk.
//
//	{"v":1,"origin":"<device>","created":<unix-ms>,"ttl_s":<int>,
//	 "mime":"text/plain;charset=utf-8"|"image/png","data":"<base64>"}
//
// Data is []byte, so encoding/json base64-encodes it: every byte (NUL, CR,
// invalid UTF-8) survives byte-exactly. Errors never include payload bytes —
// they end up in logs (sp039 anti-pattern: no payload in an error path).
package entry

import (
	"encoding/json"
	"errors"
	"fmt"
)

const (
	Version = 1

	MimeText      = "text/plain;charset=utf-8"
	MimePNG       = "image/png"
	MimeHeartbeat = "application/x-clipd-heartbeat"

	DefaultTTL = 300     // seconds
	DefaultCap = 8 << 20 // bytes of decoded Data
)

var (
	ErrEmpty    = errors.New("entry: empty payload")
	ErrTooLarge = errors.New("entry: payload over size cap")
	ErrVersion  = errors.New("entry: unknown version")
	ErrMime     = errors.New("entry: unsupported mime")
	ErrInvalid  = errors.New("entry: malformed")
)

type Entry struct {
	V       int    `json:"v"`
	Origin  string `json:"origin"`
	Created int64  `json:"created"` // unix milliseconds
	TTLs    int    `json:"ttl_s"`
	Mime    string `json:"mime"`
	Data    []byte `json:"data"`
}

// MaxEncoded bounds the encoded size of an entry whose Data is at most cap
// bytes: base64 inflation plus room for the metadata fields. Callers use it
// to cap decryption before Decode ever sees the bytes.
func MaxEncoded(cap int) int { return cap/3*4 + 8 + 4096 }

// validate checks everything except the version, which Encode sets and
// Decode checks first.
func (e Entry) validate(cap int) error {
	switch e.Mime {
	case MimeText, MimePNG:
		if len(e.Data) == 0 {
			return ErrEmpty
		}
	case MimeHeartbeat:
		if len(e.Data) != 0 {
			return fmt.Errorf("%w: heartbeat carries data", ErrInvalid)
		}
	default:
		return fmt.Errorf("%w (%d-byte mime string)", ErrMime, len(e.Mime))
	}
	if len(e.Data) > cap {
		return fmt.Errorf("%w: %d > %d bytes", ErrTooLarge, len(e.Data), cap)
	}
	if e.Origin == "" || e.Created <= 0 || e.TTLs <= 0 {
		return fmt.Errorf("%w: origin, created and ttl_s are required", ErrInvalid)
	}
	return nil
}

// Encode validates e against cap and returns its plaintext JSON. Oversize
// and empty payloads are refused here, before anything is encrypted.
func Encode(e Entry, cap int) ([]byte, error) {
	e.V = Version
	if err := e.validate(cap); err != nil {
		return nil, err
	}
	return json.Marshal(e)
}

// Decode parses and validates plaintext JSON. cap is this host's cap, not
// the writer's: a peer configured larger cannot push past it.
func Decode(b []byte, cap int) (Entry, error) {
	if len(b) > MaxEncoded(cap) {
		return Entry{}, fmt.Errorf("%w: %d encoded bytes", ErrTooLarge, len(b))
	}
	var e Entry
	if err := json.Unmarshal(b, &e); err != nil {
		// json errors can quote input; report only the class.
		return Entry{}, ErrInvalid
	}
	if e.V != Version {
		return Entry{}, fmt.Errorf("%w: %d", ErrVersion, e.V)
	}
	if err := e.validate(cap); err != nil {
		return Entry{}, err
	}
	return e, nil
}
