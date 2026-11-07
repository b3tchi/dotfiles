package agent

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"clipd/internal/entry"
	"clipd/internal/winclip"
)

// fakeClip is a scripted clipboard. Each View serves the next state in
// script (the last one repeats) and records every payload read.
type fakeClip struct {
	seq    uint32
	script []fakeState
	views  int
	reads  []string // "text" / "image" — payload reads only
	busy   bool
}

type fakeState struct {
	formats []winclip.Format
	text    []byte
	image   []byte
}

func (f *fakeClip) Seq() uint32 { return f.seq }

func (f *fakeClip) View(fn func(WinView) error) error {
	if f.busy {
		return winclip.ErrBusy
	}
	i := f.views
	if i >= len(f.script) {
		i = len(f.script) - 1
	}
	f.views++
	return fn(fakeView{f, f.script[i]})
}

type fakeView struct {
	f *fakeClip
	s fakeState
}

func (v fakeView) Formats() ([]winclip.Format, error) { return v.s.formats, nil }
func (v fakeView) Text(max int) ([]byte, error) {
	v.f.reads = append(v.f.reads, "text")
	if len(v.s.text) > max {
		return nil, winclip.ErrTooLarge
	}
	return v.s.text, nil
}
func (v fakeView) Image(max int) ([]byte, error) {
	v.f.reads = append(v.f.reads, "image")
	if len(v.s.image) > max {
		return nil, winclip.ErrTooLarge
	}
	return v.s.image, nil
}

// copyText makes the fake hold a fresh plain text copy.
func (f *fakeClip) copyText(s string, extra ...winclip.Format) {
	f.seq++
	f.views = 0
	fs := append([]winclip.Format{{ID: winclip.CFUnicodeText, Name: "CF_UNICODETEXT"}}, extra...)
	f.script = []fakeState{{formats: fs, text: []byte(s)}}
}

var (
	fmtText    = winclip.Format{ID: winclip.CFUnicodeText, Name: "CF_UNICODETEXT"}
	fmtDIB     = winclip.Format{ID: winclip.CFDIB, Name: "CF_DIB"}
	fmtExclude = winclip.Format{ID: 0xC101, Name: winclip.ExcludeName}
	fmtOLE     = []winclip.Format{{ID: 0xC009, Name: "DataObject"}, {ID: 0xC00E, Name: "Ole Private Data"}}
)

type memSink struct{ entries []entry.Entry }

func (m *memSink) Write(e entry.Entry) (string, error) {
	m.entries = append(m.entries, e)
	return "0123456789abcdef", nil
}

func newAgent(c *fakeClip) (*WinAgent, *memSink, *[]time.Duration, *[]string) {
	sink := &memSink{}
	var slept []time.Duration
	var logs []string
	a := &WinAgent{
		Clip: c, Sink: sink, Cap: 1 << 20, TTL: 300,
		Sleep: func(d time.Duration) { slept = append(slept, d) },
		Logf:  func(f string, args ...any) { logs = append(logs, strings.TrimSpace(fmt.Sprintf(f, args...))) },
	}
	return a, sink, &slept, &logs
}

func TestDedupeBySeqAndHash(t *testing.T) {
	c := &fakeClip{}
	a, sink, _, _ := newAgent(c)
	a.Prime()

	// One copy, three events on the same sequence number → one entry,
	// one payload read.
	c.copyText("hello")
	got := []WinOutcome{a.Handle(), a.Handle(), a.Handle()}
	if want := []WinOutcome{WinWritten, WinSameSeq, WinSameSeq}; !equal(got, want) {
		t.Fatalf("outcomes %v, want %v", got, want)
	}
	if len(c.reads) != 1 {
		t.Fatalf("payload reads %v, want 1", c.reads)
	}

	// The owner re-sets the same content (new seq, same bytes) → dup.
	c.copyText("hello")
	if o := a.Handle(); o != WinDup {
		t.Fatalf("same content new seq: %v", o)
	}

	// Burst of 5 distinct copies → 5 entries in order.
	for _, s := range []string{"a", "b", "c", "d", "e"} {
		c.copyText(s)
		a.Handle()
		a.Handle() // the echo event of the same copy
	}
	if len(sink.entries) != 6 {
		t.Fatalf("entries %d, want 6", len(sink.entries))
	}
	for i, s := range []string{"hello", "a", "b", "c", "d", "e"} {
		e := sink.entries[i]
		if string(e.Data) != s || e.Mime != entry.MimeText || e.TTLs != 300 {
			t.Fatalf("entry %d: %q %s ttl %d", i, e.Data, e.Mime, e.TTLs)
		}
	}
}

func TestPrimeSkipsPreexistingCopy(t *testing.T) {
	c := &fakeClip{}
	c.copyText("before start")
	a, sink, _, _ := newAgent(c)
	a.Prime()
	if o := a.Handle(); o != WinSameSeq || len(sink.entries) != 0 || len(c.reads) != 0 {
		t.Fatalf("outcome %v, entries %d, reads %v", o, len(sink.entries), c.reads)
	}
}

func TestDelayedRenderReread(t *testing.T) {
	c := &fakeClip{seq: 7}
	a, sink, slept, _ := newAgent(c)
	a.Prime()

	// First view: only OLE formats (late render). Second: the text.
	c.seq++
	c.script = []fakeState{
		{formats: fmtOLE},
		{formats: append([]winclip.Format{fmtText}, fmtOLE...), text: []byte("late")},
	}
	if o := a.Handle(); o != WinWritten {
		t.Fatalf("outcome %v", o)
	}
	if len(*slept) != 1 || (*slept)[0] != WinRereadDelay {
		t.Fatalf("slept %v, want one %v", *slept, WinRereadDelay)
	}
	if len(sink.entries) != 1 || string(sink.entries[0].Data) != "late" {
		t.Fatalf("entries %+v", sink.entries)
	}

	// Text format present but empty on the first read → same re-read.
	c.seq++
	c.views = 0
	c.script = []fakeState{{formats: []winclip.Format{fmtText}}, {formats: []winclip.Format{fmtText}, text: []byte("later")}}
	if o := a.Handle(); o != WinWritten || string(sink.entries[1].Data) != "later" {
		t.Fatalf("empty-text reread: %v", o)
	}

	// Never rendered → exactly one re-read, then skip, and the seq stays
	// unsettled so a later event for it is still processed.
	c.seq++
	c.views = 0
	c.script = []fakeState{{formats: fmtOLE}}
	*slept = nil
	if o := a.Handle(); o != WinDelayed || len(*slept) != 1 || c.views != 2 {
		t.Fatalf("never rendered: %v slept %v views %d", o, *slept, c.views)
	}
	c.script = []fakeState{{formats: []winclip.Format{fmtText}, text: []byte("finally")}}
	if o := a.Handle(); o != WinWritten {
		t.Fatalf("follow-up event for unsettled seq: %v", o)
	}
}

func TestExcludeFormatSkipsRead(t *testing.T) {
	for _, order := range [][]winclip.Format{
		{fmtExclude, fmtText},
		{fmtText, fmtDIB, fmtExclude}, // marker after the payload formats
	} {
		c := &fakeClip{}
		a, sink, slept, _ := newAgent(c)
		a.Prime()
		c.seq++
		c.script = []fakeState{{formats: order, text: []byte("hunter2"), image: []byte("x")}}
		if o := a.Handle(); o != WinExcluded {
			t.Fatalf("outcome %v", o)
		}
		if len(c.reads) != 0 || len(sink.entries) != 0 || len(*slept) != 0 {
			t.Fatalf("reads %v entries %d slept %v", c.reads, len(sink.entries), *slept)
		}
		// Later events for the same seq do not open the clipboard again.
		if o := a.Handle(); o != WinSameSeq || c.views != 1 {
			t.Fatalf("second event: %v views %d", o, c.views)
		}
	}
}

func TestPrefersTextOverImage(t *testing.T) {
	c := &fakeClip{}
	a, sink, _, _ := newAgent(c)
	a.Prime()
	c.seq++
	c.script = []fakeState{{formats: []winclip.Format{fmtDIB, fmtText}, text: []byte("cell"), image: []byte("png")}}
	a.Handle()
	if len(sink.entries) != 1 || sink.entries[0].Mime != entry.MimeText || !equal(c.reads, []string{"text"}) {
		t.Fatalf("entries %+v reads %v", sink.entries, c.reads)
	}
	c.seq++
	c.script = []fakeState{{formats: []winclip.Format{fmtDIB}, image: []byte("\x89PNG...")}}
	a.Handle()
	if len(sink.entries) != 2 || sink.entries[1].Mime != entry.MimePNG {
		t.Fatalf("image entry %+v", sink.entries)
	}
}

func TestOverCapAndBusySkip(t *testing.T) {
	c := &fakeClip{}
	a, sink, _, logs := newAgent(c)
	a.Cap = 4
	a.Prime()
	c.seq++
	c.script = []fakeState{{formats: []winclip.Format{fmtDIB}, image: []byte("toolarge")}}
	if o := a.Handle(); o != WinSkipped || len(sink.entries) != 0 {
		t.Fatalf("over cap: %v", o)
	}
	c.copyText("x")
	c.busy = true
	if o := a.Handle(); o != WinBusy || len(sink.entries) != 0 {
		t.Fatalf("busy: %v", o)
	}
	c.busy = false // contention gone: the next event for that seq works
	if o := a.Handle(); o != WinWritten {
		t.Fatalf("after busy: %v", o)
	}
	for _, l := range *logs {
		if strings.Contains(l, "toolarge") {
			t.Fatalf("payload in log: %q", l)
		}
	}
}

func TestEchoGuardSkipsPicked(t *testing.T) {
	c := &fakeClip{}
	a, sink, _, _ := newAgent(c)
	a.StateDir = t.TempDir()
	a.Prime()
	if _, err := Pick(rigWith(t, "from peer"), "", a.StateDir, func(bool, []byte) error { return nil }); err != nil {
		t.Fatal(err)
	}
	c.copyText("from peer", winclip.Format{ID: 0xC200, Name: winclip.HistoryName})
	if o := a.Handle(); o != WinEcho || len(sink.entries) != 0 {
		t.Fatalf("pick re-sent: %v", o)
	}
	c.copyText("mine")
	if o := a.Handle(); o != WinWritten {
		t.Fatalf("plain copy after pick: %v", o)
	}
}

func TestBackoffBounded(t *testing.T) {
	var slept []time.Duration
	calls := 0
	_, err := WinBackoff(context.Background(), 7, func(d time.Duration) { slept = append(slept, d) },
		func(string, ...any) {}, func() (int, error) { calls++; return 0, errors.New("no window station") })
	if err == nil || calls != 7 {
		t.Fatalf("err %v calls %d", err, calls)
	}
	want := []time.Duration{1, 2, 4, 8, 16, 30}
	for i := range want {
		want[i] *= time.Second
	}
	if !equal(slept, want) {
		t.Fatalf("slept %v want %v", slept, want)
	}
	calls = 0
	v, err := WinBackoff(context.Background(), 5, func(time.Duration) {}, func(string, ...any) {},
		func() (int, error) {
			if calls++; calls < 3 {
				return 0, errors.New("not yet")
			}
			return 42, nil
		})
	if err != nil || v != 42 || calls != 3 {
		t.Fatalf("v %d err %v calls %d", v, err, calls)
	}
}

func equal[T comparable](a, b []T) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
