package main

import (
	"bytes"
	"os"
	"strings"
	"testing"
)

// loadFixture reads a fixture file under fixtures/svg, failing the test on
// any read error (the fixture is committed; a missing file is a test setup
// bug, not a case to degrade around).
func loadFixture(t *testing.T, name string) []byte {
	t.Helper()
	data, err := os.ReadFile("fixtures/svg/" + name)
	if err != nil {
		t.Fatalf("loadFixture(%s): %v", name, err)
	}
	return data
}

// countTopLevelOpens reports how many "<svg" tag opens data starts with
// back-to-back (i.e. the wrapper depth) — 2 for d2's raw nested output, 1
// once flattened.
func leadingSVGOpenCount(data []byte) int {
	count := 0
	i := bytes.Index(data, []byte("<svg"))
	if i < 0 {
		return 0
	}
	for {
		idx := bytes.Index(data[i:], []byte("<svg"))
		if idx != 0 {
			break
		}
		count++
		end := bytes.IndexByte(data[i:], '>')
		if end < 0 {
			break
		}
		i += end + 1
		// only continue if immediately (mod whitespace) followed by another <svg
		j := i
		for j < len(data) && (data[j] == ' ' || data[j] == '\t' || data[j] == '\n' || data[j] == '\r') {
			j++
		}
		if !bytes.HasPrefix(data[j:], []byte("<svg")) {
			break
		}
		i = j
	}
	return count
}

func TestFlattenD2SVG_NestedWrapper_PromotesInnerToRoot(t *testing.T) {
	nested := loadFixture(t, "nested.svg")

	if got := leadingSVGOpenCount(nested); got != 2 {
		t.Fatalf("fixture sanity: want 2 leading nested <svg opens, got %d", got)
	}

	flat := flattenD2SVG(nested)

	if got := leadingSVGOpenCount(flat); got != 1 {
		t.Fatalf("flattened output still has %d leading nested <svg opens, want 1:\n%s", got, truncate(flat, 300))
	}

	// The real content (background rect, style block, paths — everything
	// between the inner tag's '>' and its own closing tag) must survive
	// byte-for-byte; only the two tag headers/footers change.
	if !bytes.Contains(flat, []byte(`class="d2-`)) {
		t.Errorf("flattened output lost the d2 content class marker")
	}
	if !bytes.Contains(flat, []byte("<style")) {
		t.Errorf("flattened output lost the <style> block")
	}

	// Attributes that only existed on the outer wrapper (xmlns, xmlns:xlink,
	// preserveAspectRatio, data-d2-version) must be promoted onto the new
	// root so the document stays valid/renderable outside a browser.
	for _, want := range []string{
		`xmlns="http://www.w3.org/2000/svg"`,
		`xmlns:xlink="http://www.w3.org/1999/xlink"`,
		`data-d2-version="v0.7.1"`,
		`preserveAspectRatio="xMinYMin meet"`,
	} {
		if !bytes.Contains(flat, []byte(want)) {
			t.Errorf("flattened output missing promoted attribute %q", want)
		}
	}

	// The inner svg's own attributes (width/height/viewBox/class) — the
	// ones that actually matter for correct rendering — must win over
	// anything on the outer (notably viewBox: outer's is the plain 0,0,W,H
	// canvas box, inner's carries the real content offset).
	svgStart := bytes.Index(flat, []byte("<svg"))
	rootTag := flat[svgStart : svgStart+bytes.IndexByte(flat[svgStart:], '>')+1]
	if !strings.Contains(string(rootTag), `viewBox="-1 -1 55 234"`) {
		t.Errorf("root tag lost inner's offset viewBox, got: %s", rootTag)
	}
	if strings.Count(string(rootTag), "viewBox=") != 1 {
		t.Errorf("root tag must carry exactly one viewBox attribute, got: %s", rootTag)
	}

	// Exactly one root element: the two closing "</svg></svg>" at the tail
	// of the original collapse into a single "</svg>".
	trimmed := bytes.TrimRight(flat, "\r\n\t ")
	if !bytes.HasSuffix(trimmed, []byte("</svg>")) {
		t.Fatalf("flattened output must end in a single </svg>, got tail: %s", truncate(trimmed, 60))
	}
	if bytes.HasSuffix(trimmed, []byte("</svg></svg>")) {
		t.Fatalf("flattened output still ends in a double </svg></svg>")
	}
}

func TestFlattenD2SVG_AlreadyFlat_Idempotent(t *testing.T) {
	nested := loadFixture(t, "nested.svg")

	once := flattenD2SVG(nested)
	twice := flattenD2SVG(once)

	if !bytes.Equal(once, twice) {
		t.Fatalf("flattenD2SVG is not idempotent:\nonce:  %s\ntwice: %s", truncate(once, 200), truncate(twice, 200))
	}
}

func TestFlattenD2SVG_GenericSingleRootSVG_Unchanged(t *testing.T) {
	// A plain, ordinary single-root SVG unrelated to d2 — the common case
	// for any non-d2 caller of this same code path (there currently is
	// none, but the function must not corrupt arbitrary well-formed SVG
	// that never had a wrapper).
	generic := []byte(`<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>`)

	got := flattenD2SVG(generic)

	if !bytes.Equal(got, generic) {
		t.Fatalf("generic single-root svg was mutated:\nwant: %s\ngot:  %s", generic, got)
	}
}

func TestFlattenD2SVG_Truncated_NoPanicDegradesToUnchanged(t *testing.T) {
	nested := loadFixture(t, "nested.svg")

	cases := map[string][]byte{
		"cut mid-outer-tag":    nested[:20],
		"cut mid-inner-tag":    nested[:len(bytes.SplitAfter(nested, []byte("<svg class="))[0])+5],
		"cut before closers":   nested[:len(nested)-20],
		"cut one closing only": nested[:len(nested)-len("</svg>")],
		"empty":                {},
	}

	for name, data := range cases {
		t.Run(name, func(t *testing.T) {
			defer func() {
				if r := recover(); r != nil {
					t.Fatalf("flattenD2SVG panicked on %s input: %v", name, r)
				}
			}()
			got := flattenD2SVG(data)
			if !bytes.Equal(got, data) {
				t.Errorf("%s: want unchanged passthrough on unmatched shape\nwant: %s\ngot:  %s", name, truncate(data, 120), truncate(got, 120))
			}
		})
	}
}

func TestFlattenD2SVG_NonSVGBytes_Untouched(t *testing.T) {
	cases := [][]byte{
		[]byte(`{"not":"svg"}`),
		[]byte("plain text, no markup at all"),
		nil,
		{},
	}
	for _, data := range cases {
		got := flattenD2SVG(data)
		if !bytes.Equal(got, data) {
			t.Errorf("non-svg input mutated: want %q, got %q", data, got)
		}
	}
}

func truncate(b []byte, n int) []byte {
	if len(b) <= n {
		return b
	}
	return append(append([]byte{}, b[:n]...), []byte("...<truncated>")...)
}
