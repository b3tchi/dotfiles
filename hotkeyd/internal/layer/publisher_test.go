package layer

// python: hotkeyd/layers.py's StatePublisher + socket_path (test_layers.py
// lines 650-889, sp021 Task 8 / bd dotfiles-ylmp.7). Deliberately NOT a
// byte-for-byte port: the accept-time replay contract this task implements
// is the one Python VIOLATES (bd dotfiles-4uiu — StatePublisher._current
// stays None until the first layer change, so a fresh client that connects
// before any change gets nothing). This package seeds `current` with an
// explicit initial state at construction, so replay-on-connect always
// answers — see NewStatePublisher's doc.

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func sockPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(t.TempDir(), "hotkeyd-test.sock")
}

// testConn pairs a connection with ONE bufio.Reader that outlives
// individual readLine calls — bufio.Reader.Read pulls whatever the kernel
// currently has buffered (which may span several already-written lines),
// so a fresh bufio.Reader per call would silently swallow bytes belonging
// to a later line into a reader nobody keeps.
type testConn struct {
	*net.UnixConn
	r *bufio.Reader
}

func dial(t *testing.T, path string) *testConn {
	t.Helper()
	c, err := net.DialUnix("unix", nil, &net.UnixAddr{Name: path, Net: "unix"})
	if err != nil {
		t.Fatalf("dial %s: %v", path, err)
	}
	return &testConn{UnixConn: c, r: bufio.NewReader(c)}
}

// readLine reads one newline-terminated line with a bounded deadline, so a
// test that regresses the accept-time-replay contract fails fast rather
// than hanging the suite.
func readLine(t *testing.T, c *testConn) string {
	t.Helper()
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	line, err := c.r.ReadString('\n')
	if err != nil {
		t.Fatalf("readLine: %v", err)
	}
	return line
}

// waitForClientCount polls until the publisher's registered-client count
// reaches want, or fails the test. Used to synchronize a test's Publish
// call against the accept goroutine's own registration, which happens on
// its own goroutine.
func waitForClientCount(t *testing.T, p *StatePublisher, want int) {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if p.ClientCount() == want {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatalf("ClientCount never reached %d (last=%d)", want, p.ClientCount())
}

// -- SocketPath -----------------------------------------------------------

func TestSocketPathNormalisesDisplayAndUsesXDGRuntimeDir(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)

	got := SocketPath(":10.0")
	want := filepath.Join(dir, "hotkeyd-10.sock")
	if got != want {
		t.Fatalf("SocketPath(%q) = %q, want %q", ":10.0", got, want)
	}

	// ":10.0" and ":10" must collide on one socket (the shared
	// proc.NormalizeDisplay rule Task 10's paths.go also uses).
	if SocketPath(":10.0") != SocketPath(":10") {
		t.Fatalf("SocketPath(%q) != SocketPath(%q), want equal", ":10.0", ":10")
	}
}

// -- construction -----------------------------------------------------------

func TestNewStatePublisherCreatesTheSocketAndAClientCanConnect(t *testing.T) {
	path := sockPath(t)
	p, err := NewStatePublisher(path, State{Layer: DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer p.Close()

	if _, err := os.Stat(path); err != nil {
		t.Fatalf("socket file not created: %v", err)
	}
	c := dial(t, path)
	c.Close()
}

// -- accept-time replay (the whole point of this task) ----------------------

func TestAcceptTimeReplayIsByteExactBeforeAnyChange(t *testing.T) {
	path := sockPath(t)
	initial := State{Layer: "nav", Mod: "move"}
	p, err := NewStatePublisher(path, initial)
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer p.Close()

	c := dial(t, path)
	defer c.Close()

	// No Publish has been called at all: the FIRST line this client reads
	// must already be the state the publisher was constructed with. This
	// is the deliberate divergence from Python's ChannelUnavailable-free
	// `_current: dict | None = None` (bd dotfiles-4uiu).
	got := readLine(t, c)
	want := `{"layer":"nav","mod":"move"}` + "\n"
	if got != want {
		t.Fatalf("replay line = %q, want %q", got, want)
	}
}

func TestAcceptTimeReplayOrdersBeforeALaterPublish(t *testing.T) {
	path := sockPath(t)
	p, err := NewStatePublisher(path, State{Layer: DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer p.Close()

	c := dial(t, path)
	defer c.Close()

	// Wait for the accept goroutine to have actually registered this
	// client before publishing a change — proves the ordering guarantee
	// is structural (replay happens INSIDE accept, under the same lock
	// Publish uses), not a race that happens to resolve favourably.
	waitForClientCount(t, p, 1)
	p.Publish(State{Layer: "nav", Mod: "move"})

	first := readLine(t, c)
	second := readLine(t, c)
	if first != `{"layer":"default","mod":null}`+"\n" {
		t.Fatalf("first line = %q, want the replayed default state", first)
	}
	if second != `{"layer":"nav","mod":"move"}`+"\n" {
		t.Fatalf("second line = %q, want the published change", second)
	}
}

func TestClientConnectingMidHoldGetsTheHeldStateReplayed(t *testing.T) {
	// Edge case: "Client connects while a hold layer is active mid-gesture."
	path := sockPath(t)
	p, err := NewStatePublisher(path, State{Layer: DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer p.Close()

	p.Publish(State{Layer: "switcher", Mod: ""})

	c := dial(t, path)
	defer c.Close()
	got := readLine(t, c)
	want := `{"layer":"switcher","mod":null}` + "\n"
	if got != want {
		t.Fatalf("replay line = %q, want %q", got, want)
	}
}

// -- fan-out ------------------------------------------------------------

func TestPublishFansOutToNClientsInOrder(t *testing.T) {
	path := sockPath(t)
	p, err := NewStatePublisher(path, State{Layer: DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer p.Close()

	a := dial(t, path)
	defer a.Close()
	b := dial(t, path)
	defer b.Close()
	waitForClientCount(t, p, 2)

	p.Publish(State{Layer: "nav", Mod: ""})
	p.Publish(State{Layer: "nav", Mod: "resize"})

	for _, c := range []*testConn{a, b} {
		_ = readLine(t, c) // replay (default)
		l1 := readLine(t, c)
		l2 := readLine(t, c)
		if l1 != `{"layer":"nav","mod":null}`+"\n" {
			t.Fatalf("client got %q, want the first change", l1)
		}
		if l2 != `{"layer":"nav","mod":"resize"}`+"\n" {
			t.Fatalf("client got %q, want the second change", l2)
		}
	}
}

// -- wedged / dead / garbage-writing clients (adr0012) -----------------------

func TestAWedgedClientNeverBlocksPublishToTheLiveOne(t *testing.T) {
	path := sockPath(t)
	p, err := NewStatePublisher(path, State{Layer: DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer p.Close()

	wedged := dial(t, path) // never reads
	defer wedged.Close()
	live := dial(t, path)
	defer live.Close()
	waitForClientCount(t, p, 2)
	// Drain both replay lines from the live client so its buffer is not
	// what's tested here.
	_ = readLine(t, live)

	done := make(chan struct{})
	go func() {
		// Far beyond the unix-domain-socket send buffer: if a wedged
		// reader could block Publish, this would hang the test.
		for i := 0; i < 5000; i++ {
			p.Publish(State{Layer: "nav", Mod: "x"})
		}
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("Publish blocked on a reader that never reads")
	}

	// The live client must still have received the flood (last-value at
	// minimum: at least one line arrives).
	_ = live.SetReadDeadline(time.Now().Add(2 * time.Second))
	buf := make([]byte, 64)
	n, err := live.Read(buf)
	if err != nil || n == 0 {
		t.Fatalf("live client received nothing after the flood: n=%d err=%v", n, err)
	}
}

func TestADeadClientIsReapedNotMerelyTolerated(t *testing.T) {
	path := sockPath(t)
	p, err := NewStatePublisher(path, State{Layer: DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer p.Close()

	c := dial(t, path)
	waitForClientCount(t, p, 1)
	c.Close() // gone; unread data may still be "in flight" from the client's pov

	// Publish enough times that a write is attempted against the closed
	// fd — a single publish is not guaranteed to observe ECONNRESET on
	// unix sockets immediately depending on OS buffering, so retry a
	// bounded number of times.
	deadline := time.Now().Add(2 * time.Second)
	for p.ClientCount() != 0 && time.Now().Before(deadline) {
		p.Publish(State{Layer: "nav", Mod: ""})
		time.Sleep(5 * time.Millisecond)
	}
	if p.ClientCount() != 0 {
		t.Fatalf("dead client was not reaped: ClientCount=%d", p.ClientCount())
	}

	// A fresh client must still be served after the dead one is reaped.
	survivor := dial(t, path)
	defer survivor.Close()
	got := readLine(t, survivor)
	if got == "" {
		t.Fatal("survivor got nothing after the dead client was reaped")
	}
}

func TestAGarbageWritingClientIsIgnoredNotActedOn(t *testing.T) {
	// adr0012: bars are read-only; mutation never flows back. The
	// publisher must never read application data from a client — it
	// only writes. Writing garbage back must not disturb the daemon
	// (no panic, no crash, no effect on fan-out to other clients).
	path := sockPath(t)
	p, err := NewStatePublisher(path, State{Layer: DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	defer p.Close()

	garbage := dial(t, path)
	defer garbage.Close()
	live := dial(t, path)
	defer live.Close()
	waitForClientCount(t, p, 2)

	if _, err := garbage.Write([]byte("not json at all\x00\x01garbage\n")); err != nil {
		t.Fatalf("garbage write: %v", err)
	}

	p.Publish(State{Layer: "nav", Mod: ""})

	_ = readLine(t, live) // replay
	got := readLine(t, live)
	if got != `{"layer":"nav","mod":null}`+"\n" {
		t.Fatalf("live client got %q after a garbage-writing peer, want the change unaffected", got)
	}
}

// -- stale socket / busy directory (SIGKILLed predecessor) -------------------

func TestStaleSocketFileFromAKilledPredecessorIsRebound(t *testing.T) {
	path := sockPath(t)
	if err := os.WriteFile(path, nil, 0o644); err != nil {
		t.Fatalf("seed stale file: %v", err)
	}

	p, err := NewStatePublisher(path, State{Layer: DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher over a stale socket file: %v", err)
	}
	defer p.Close()

	c := dial(t, path)
	c.Close()
}

func TestVanishedRuntimeDirFailsNamedInsteadOfPanicking(t *testing.T) {
	// Edge case: "$XDG_RUNTIME_DIR vanishes under the daemon -> publish
	// fails named, daemon survives." Modelled at construction: the
	// parent directory does not exist.
	missing := filepath.Join(t.TempDir(), "gone", "hotkeyd-10.sock")
	_, err := NewStatePublisher(missing, State{Layer: DefaultLayer})
	if err == nil {
		t.Fatal("expected an error constructing a publisher under a missing directory")
	}
	var cu *ErrChannelUnavailable
	if !errors.As(err, &cu) {
		t.Fatalf("error = %v (%T), want *ErrChannelUnavailable", err, err)
	}
	if cu.Path == "" {
		t.Fatal("ErrChannelUnavailable did not name the path")
	}
}

// -- close ----------------------------------------------------------------

func TestCloseRemovesTheSocketFile(t *testing.T) {
	path := sockPath(t)
	p, err := NewStatePublisher(path, State{Layer: DefaultLayer})
	if err != nil {
		t.Fatalf("NewStatePublisher: %v", err)
	}
	if err := p.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Fatalf("socket file still exists after Close: err=%v", err)
	}
}

// -- wire format: JSON schema golden test against the recorded Python daemon
// output (json.dumps(state, separators=(",", ":")) on hotkeyd/layers.py's
// StatePublisher._send) -----------------------------------------------------

func TestWireFormatMatchesRecordedPythonDaemonOutput(t *testing.T) {
	// Recorded 2026-07-30 via:
	//   python3 -c "import json; print(json.dumps(<state>, separators=(',', ':')))"
	// against hotkeyd/layers.py's exact StatePublisher._send encoding.
	cases := []struct {
		name  string
		state State
		want  string
	}{
		{"active sublayer", State{Layer: "nav", Mod: "move"}, `{"layer":"nav","mod":"move"}`},
		{"default, no mod", State{Layer: "default", Mod: ""}, `{"layer":"default","mod":null}`},
		{"layer, no mod", State{Layer: "nav", Mod: ""}, `{"layer":"nav","mod":null}`},
		{"other sublayer", State{Layer: "switcher", Mod: "resize"}, `{"layer":"switcher","mod":"resize"}`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			line := encodeStateLine(c.state)
			if string(line) != c.want+"\n" {
				t.Fatalf("encodeStateLine(%+v) = %q, want %q", c.state, line, c.want+"\n")
			}
			// Round-trip through encoding/json to prove the two fields
			// ft009's Bar.qml / qs-focus-border.py rely on ("layer" a
			// string, "mod" a string-or-null) are exactly what's on the
			// wire, not merely byte-equal to a hand-written string.
			var decoded map[string]any
			trimmed := line[:len(line)-1]
			if err := json.Unmarshal(trimmed, &decoded); err != nil {
				t.Fatalf("wire line is not valid JSON: %v", err)
			}
			if _, ok := decoded["layer"].(string); !ok {
				t.Fatalf("decoded[layer] = %#v, want a string", decoded["layer"])
			}
			if c.state.Mod == "" {
				if decoded["mod"] != nil {
					t.Fatalf("decoded[mod] = %#v, want nil (JSON null)", decoded["mod"])
				}
			} else if decoded["mod"] != c.state.Mod {
				t.Fatalf("decoded[mod] = %#v, want %q", decoded["mod"], c.state.Mod)
			}
		})
	}
}
