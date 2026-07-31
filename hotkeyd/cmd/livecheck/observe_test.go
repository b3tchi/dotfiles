package main

import (
	"errors"
	"strings"
	"testing"
)

var errUnparsableForTest = errors.New("junk on the wire")

func TestParseStateLine_ReadsTheWireFormatTheDaemonActuallyEmits(t *testing.T) {
	for _, tc := range []struct {
		line      string
		wantLayer string
		wantMod   string
	}{
		{`{"layer":"default","mod":null}`, "default", ""},
		{`{"layer":"nav","mod":"move"}`, "nav", "move"},
		{`{"layer":"switcher","mod":null}`, "switcher", ""},
	} {
		got, err := parseStateLine(tc.line)
		if err != nil {
			t.Errorf("%s: %v", tc.line, err)
			continue
		}
		if got.Layer != tc.wantLayer || got.Mod != tc.wantMod {
			t.Errorf("%s: got layer=%q mod=%q, want %q/%q", tc.line, got.Layer, got.Mod, tc.wantLayer, tc.wantMod)
		}
	}
}

func TestParseStateLine_RejectsNonState(t *testing.T) {
	for _, line := range []string{``, `not json`, `{"nope":1}`} {
		if _, err := parseStateLine(line); err == nil {
			t.Errorf("%q parsed as a state line", line)
		}
	}
}

// The transition log is the evidence hwds.27 had none of. What matters is
// not that a line appears but that the DISCRIMINATING fields are filled with
// real values off a real server — each one is "none" unless the whole
// XI2 -> event -> engine chain carries it.
func TestParseTransition_ExtractsEveryDiscriminatingField(t *testing.T) {
	line := `hotkeyd: transition layer=default->nav mod=none->none trigger=press:o ` +
		`keycode=32 mask=0x0040 mods=Mod4 sourceid=5 device="Virtual core XTEST keyboard" held=none i3_mode=default`
	tr, ok := parseTransition(line)
	if !ok {
		t.Fatal("a real transition line did not parse")
	}
	if tr.From != "default" || tr.To != "nav" {
		t.Errorf("layer %q->%q, want default->nav", tr.From, tr.To)
	}
	if tr.Keycode != "32" {
		t.Errorf("keycode=%q, want 32", tr.Keycode)
	}
	if tr.Mask != 0x0040 {
		t.Errorf("mask=%#x, want 0x40", tr.Mask)
	}
	if !tr.MaskPresent {
		t.Error("mask reported absent on a line that carries it")
	}
	if tr.SourceID != "5" {
		t.Errorf("sourceid=%q, want 5", tr.SourceID)
	}
	if tr.Device != "Virtual core XTEST keyboard" {
		t.Errorf("device=%q", tr.Device)
	}
	if tr.Trigger != "press:o" {
		t.Errorf("trigger=%q", tr.Trigger)
	}
}

// A daemon that logged from engine state alone writes "none" into exactly
// these fields — so parsing must distinguish "none" from a real value
// rather than treating the line's presence as the evidence.
func TestParseTransition_NoneIsNotAValue(t *testing.T) {
	line := `hotkeyd: transition layer=nav->default mod=none->none trigger=none held=none i3_mode=default`
	tr, ok := parseTransition(line)
	if !ok {
		t.Fatal("did not parse")
	}
	if tr.MaskPresent {
		t.Error("a line with no mask= field reported one")
	}
	if tr.Keycode != "" || tr.SourceID != "" || tr.Device != "" {
		t.Errorf("absent fields came back non-empty: keycode=%q sourceid=%q device=%q", tr.Keycode, tr.SourceID, tr.Device)
	}
}

func TestParseTransition_NoneLiteralsAreEmpty(t *testing.T) {
	line := `hotkeyd: transition layer=nav->default mod=none->none trigger=press:q keycode=none mask=none mods=none sourceid=none device=none held=none i3_mode=default`
	tr, ok := parseTransition(line)
	if !ok {
		t.Fatal("did not parse")
	}
	if tr.Keycode != "" {
		t.Errorf("keycode=none decoded as %q — 'none' means the daemon could not resolve it", tr.Keycode)
	}
	if tr.SourceID != "" || tr.Device != "" || tr.MaskPresent {
		t.Errorf("a fully-none line reported values: %+v", tr)
	}
}

func TestParseTransition_IgnoresOtherDaemonLines(t *testing.T) {
	for _, line := range []string{
		"hotkeyd: 133 chords grabbed on :871 via XI2 ($mod=Mod4)",
		"hotkeyd: i3: subscribe: whatever",
		"",
	} {
		if _, ok := parseTransition(line); ok {
			t.Errorf("%q parsed as a transition", line)
		}
	}
}

func TestGrabbedChordCount_ReadsTheStartupLine(t *testing.T) {
	n, mod, ok := parseGrabSummary("hotkeyd: 133 chords grabbed on :871 via XI2 ($mod=Mod1)")
	if !ok {
		t.Fatal("the startup line did not parse")
	}
	if n != 133 {
		t.Errorf("count=%d, want 133", n)
	}
	if mod != "Mod1" {
		t.Errorf("mod=%q, want Mod1", mod)
	}
	if _, _, ok := parseGrabSummary("hotkeyd: something else"); ok {
		t.Error("an unrelated line parsed as the grab summary")
	}
}

func TestLogSink_KeepsEveryLineForLaterQuestions(t *testing.T) {
	var s logSink
	s.Write([]byte("hotkeyd: one\nhotkeyd: two\n"))
	s.Write([]byte("hotkeyd: three\n"))
	got := s.Lines()
	if len(got) != 3 || got[2] != "hotkeyd: three" {
		t.Fatalf("got %q", got)
	}
	s.Reset()
	if got := s.Lines(); len(got) != 0 {
		t.Errorf("after Reset: %q", got)
	}
}

func TestLogSink_HandlesAPartialLineAcrossWrites(t *testing.T) {
	var s logSink
	s.Write([]byte("hotkeyd: par"))
	s.Write([]byte("tial\n"))
	got := s.Lines()
	if len(got) != 1 || got[0] != "hotkeyd: partial" {
		t.Fatalf("got %q, want one reassembled line", got)
	}
	if strings.Contains(strings.Join(got, "|"), "par|") {
		t.Error("the line was split across writes")
	}
}

// PARITY FINDING (this task): the two daemons quote the transition log's
// device= field differently — Go's formatTransition uses %q, hotkeyd.py's
// format_transition uses Python's !r. Both are parsed, so this tool can
// grade either engine; the divergence is reported to the parity gate rather
// than hidden by only understanding one spelling.
func TestParseTransition_AcceptsBothEnginesDeviceQuoting(t *testing.T) {
	for name, line := range map[string]string{
		"go":     `hotkeyd: transition layer=default->nav mod=none->none trigger=press:o keycode=32 mask=0x0040 mods=Mod4 sourceid=5 device="Virtual core XTEST keyboard" held=none i3_mode=default`,
		"python": `hotkeyd: transition layer=default->nav mod=none->none trigger=press:o keycode=32 mask=0x0040 mods=Mod4 sourceid=5 device='Virtual core XTEST keyboard' held=none i3_mode=default`,
	} {
		tr, ok := parseTransition(line)
		if !ok {
			t.Errorf("%s: did not parse", name)
			continue
		}
		if tr.Device != "Virtual core XTEST keyboard" {
			t.Errorf("%s: device=%q, want the unquoted name", name, tr.Device)
		}
	}
}

// SWALLOW-YOUR-OWN-FAILURE (flagged by the 3rd audit). The tail records a
// parse failure and every state claim renders the recorded states — so a
// line the OBSERVER could not read prints as "no state was published at
// all", the daemon's failure. Describe is where that error surfaces.
func TestStateWatcher_DescribeNamesALineTheTailCouldNotParse(t *testing.T) {
	var w StateWatcher
	if got := w.Describe(); got != "no state was published at all" {
		t.Fatalf("a clean empty tail rendered as %q", got)
	}
	w.err = errUnparsableForTest
	got := w.Describe()
	if !strings.Contains(got, "could not be parsed") || !strings.Contains(got, "junk on the wire") {
		t.Fatalf("Describe() = %q — a parse failure must be visible, not read as daemon silence", got)
	}
}

// With no parse failure the rendering is byte-identical to describeStates',
// so surfacing the error changes no detail line on a healthy run.
func TestStateWatcher_DescribeMatchesDescribeStatesWhenNothingFailed(t *testing.T) {
	var w StateWatcher
	w.states = []State{{Layer: "default"}, {Layer: "nav", Mod: "move"}}
	if got, want := w.Describe(), describeStates(w.States()); got != want {
		t.Fatalf("Describe() = %q, describeStates() = %q", got, want)
	}
}

func TestUnquoteEitherEngine_LeavesUnquotableInputAlone(t *testing.T) {
	if got := unquoteEitherEngine("none"); got != "none" {
		t.Errorf("got %q", got)
	}
}
