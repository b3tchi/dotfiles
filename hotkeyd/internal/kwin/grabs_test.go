package kwin

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var testSyms = map[string]uint32{
	"Return": 0xff0d, "q": 'q', "1": '1', "a": 'a', "Left": 0xff51, "Tab": 0xff09,
}

func lookup(n string) (uint32, bool) { v, ok := testSyms[n]; return v, ok }

type fake struct {
	l    net.Listener
	path string
	conn chan net.Conn
}

func newFake(t *testing.T) *fake {
	t.Helper()
	p := filepath.Join(os.TempDir(), "kwk"+strings.ReplaceAll(t.Name(), "/", "_")+".sock")
	os.Remove(p)
	l, err := net.Listen("unix", p)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close(); os.Remove(p) })
	f := &fake{l: l, path: p, conn: make(chan net.Conn, 8)}
	go func() {
		for {
			c, err := l.Accept()
			if err != nil {
				return
			}
			c.Write([]byte(`{"hello":1,"kwin":"6.8.1"}` + "\n"))
			f.conn <- c
		}
	}()
	return f
}

func (f *fake) accept(t *testing.T) (net.Conn, *bufio.Reader) {
	t.Helper()
	select {
	case c := <-f.conn:
		return c, bufio.NewReader(c)
	case <-time.After(3 * time.Second):
		t.Fatal("no client connection")
	}
	return nil, nil
}

func readLine(t *testing.T, br *bufio.Reader, c net.Conn) string {
	t.Helper()
	c.SetReadDeadline(time.Now().Add(3 * time.Second))
	s, err := br.ReadString('\n')
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return strings.TrimSpace(s)
}

func grabOf(t *testing.T, line string) []wireChord {
	t.Helper()
	var m struct{ Grab []wireChord }
	if err := json.Unmarshal([]byte(line), &m); err != nil {
		t.Fatalf("bad wire %q: %v", line, err)
	}
	return m.Grab
}

func mk(t *testing.T, f *fake) (*GrabManager, net.Conn, *bufio.Reader, *[]string) {
	t.Helper()
	var logs []string
	g, err := NewGrabManager(f.path, "Mod4", lookup, func(s string) { logs = append(logs, s) })
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(g.Close)
	c, br := f.accept(t)
	return g, c, br, &logs
}

func TestSyncBindsWire(t *testing.T) {
	f := newFake(t)
	g, c, br, _ := mk(t, f)
	g.SyncBinds([]string{"$mod+Return", "$mod+Shift+q"})
	got := readLine(t, br, c)
	want := `{"grab":[{"keysym":65293,"mods":64},{"keysym":81,"mods":65}]}`
	if got != want {
		t.Fatalf("wire:\n got %s\nwant %s", got, want)
	}
	if w, a, m := g.GrabReport(); w != 2 || a != 2 || len(m) != 0 {
		t.Fatalf("report %d %d %v", w, a, m)
	}
	if g.OnMappingNotify() {
		t.Fatal("OnMappingNotify must be a no-op")
	}
}

func TestShiftedChord(t *testing.T) {
	f := newFake(t)
	g, c, br, _ := mk(t, f)
	g.SyncBinds([]string{"$mod+Shift+1", "Shift+1", "Shift+a", "$mod+1", "$mod+Shift+Left"})
	got := grabOf(t, readLine(t, br, c))
	want := []wireChord{{0x21, 64}, {0x21, 0}, {0x41, 1}, {0x31, 64}, {0xff51, 65}}
	if len(got) != len(want) {
		t.Fatalf("got %v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("[%d] got %v want %v", i, got[i], want[i])
		}
	}
}

func TestReconnectResends(t *testing.T) {
	f := newFake(t)
	reconnectBackoff = 10 * time.Millisecond
	t.Cleanup(func() { reconnectBackoff = 100 * time.Millisecond })
	g, c, br, _ := mk(t, f)
	g.SyncBinds([]string{"$mod+Return"})
	first := readLine(t, br, c)
	c.Close() // plugin restart
	c2, br2 := f.accept(t)
	if again := readLine(t, br2, c2); again != first {
		t.Fatalf("resent %s, want %s", again, first)
	}
}

func TestUnknownKeysym(t *testing.T) {
	f := newFake(t)
	g, c, br, logs := mk(t, f)
	g.SyncBinds([]string{"$mod+Return", "$mod+nosuchkey", "$mod+F1"})
	got := grabOf(t, readLine(t, br, c))
	if len(got) != 1 || got[0].Keysym != 0xff0d {
		t.Fatalf("others must still be grabbed: %v", got)
	}
	w, a, m := g.GrabReport()
	if w != 3 || a != 1 || len(m) != 2 {
		t.Fatalf("report %d %d %v", w, a, m)
	}
	if len(*logs) != 2 {
		t.Fatalf("logs %v", *logs)
	}
}

func TestMalformedLine(t *testing.T) {
	f := newFake(t)
	g, c, _, logs := mk(t, f)
	c.Write([]byte("not json\n{\"ev\":\"press\",\"keysym\":65293,\"mods\":64,\"device\":\"kbd\"}\n{\"mods\":64}\n"))
	e1 := <-g.Events()
	if e1 != (Event{Kind: "press", Keysym: 65293, Mods: 64, Device: "kbd"}) {
		t.Fatalf("e1 %+v", e1)
	}
	if e2 := <-g.Events(); e2.Kind != "mods" || e2.Mods != 64 {
		t.Fatalf("e2 %+v", e2)
	}
	if len(*logs) != 1 || !strings.Contains((*logs)[0], "malformed") {
		t.Fatalf("logs %v", *logs)
	}
}

func TestDialFailFast(t *testing.T) {
	p := filepath.Join(t.TempDir(), "nope.sock")
	_, err := NewGrabManager(p, "Mod4", lookup, nil)
	if err == nil || !strings.Contains(err.Error(), p) {
		t.Fatalf("want error naming %s, got %v", p, err)
	}
	// busy refusal also fails
	f := newFake(t)
	f.l.Close()
	os.Remove(f.path)
	l, _ := net.Listen("unix", f.path)
	defer l.Close()
	go func() { c, _ := l.Accept(); c.Write([]byte(`{"error":"busy"}` + "\n")); c.Close() }()
	if _, err := Dial(f.path, nil); err == nil || !strings.Contains(err.Error(), "busy") {
		t.Fatalf("busy: %v", err)
	}
}
