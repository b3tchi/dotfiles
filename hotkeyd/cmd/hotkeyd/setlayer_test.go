package main

// setlayer_test.go covers the `set-layer` CLI verb (sp023 Task 4, bd
// dotfiles-1m4t.4): client-side pre-validation against the compiled table
// (mirroring control.go's validateControlLayer, reused directly here so
// both sides of the wire apply the IDENTICAL authority policy), then at
// most ONE dial against the per-display control socket (proc.ControlPath),
// one request line, one reply line, no retry (adr0014).
//
// setLayer takes its compiled-table argument explicitly rather than
// reading the package `Layers` var, purely for testability: config.go's
// shipped table has no External-declared layer yet (that lands in Task 5's
// cutover), so every test here builds its own small fixture table, the
// same way internal/layer/external_test.go's externalLayers() does.
// runSetLayerCmd (setlayer.go) is what wires the real Layers in.
//
// Every case past pre-validation runs against a REAL unix socket in
// t.TempDir(), mirroring control_test.go's own reasoning: past
// pre-validation the verb's whole job is wire framing under a deadline,
// and a fake net.Conn would silently drop the "no hang" property that
// actually matters.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/proc"
)

// setLayerTestTimeout is deliberately short so the deadline/no-hang cases
// do not take seconds -- production uses setLayerTimeout.
const setLayerTestTimeout = 150 * time.Millisecond

// externalOnly is the smallest fixture table with one External-declared
// layer -- the only name pre-validation should ever let through to a dial
// in these tests.
func externalOnly() map[string]bind.Layer {
	return map[string]bind.Layer{"screenshot-drag": {External: true}}
}

// newTestCtlListener binds a real unix listener at the SAME path
// proc.ControlPath(display) would resolve to, by pointing XDG_RUNTIME_DIR
// at a fresh t.TempDir() -- the same env-var seam
// TestDispatch_Health_RoutesToRunHealth and statetail_test.go already use.
func newTestCtlListener(t *testing.T, display string) net.Listener {
	t.Helper()
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	path := proc.ControlPath(display)
	ln, err := net.Listen("unix", path)
	if err != nil {
		t.Fatalf("listen: %s", err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln
}

// -- happy path --------------------------------------------------------

func TestSetLayer_DaemonAccepts_ExitsOKAndSendsTheRightRequest(t *testing.T) {
	display := ":81"
	ln := newTestCtlListener(t, display)

	var wg sync.WaitGroup
	wg.Add(1)
	var reqErr error
	go func() {
		defer wg.Done()
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 4096)
		n, _ := conn.Read(buf)
		var req controlRequest
		if err := json.Unmarshal(bytes.TrimSpace(buf[:n]), &req); err != nil {
			reqErr = err
		} else if req.SetLayer == nil || *req.SetLayer != "screenshot-drag" {
			reqErr = fmt.Errorf("server saw %+v, want set_layer=screenshot-drag", req)
		}
		conn.Write([]byte(`{"ok":true}` + "\n"))
	}()

	var stdout, stderr bytes.Buffer
	code := setLayer(externalOnly(), "screenshot-drag", display, setLayerTestTimeout, &stdout, &stderr)
	wg.Wait()

	if reqErr != nil {
		t.Fatalf("request assertion: %s", reqErr)
	}
	if code != SetLayerOK {
		t.Fatalf("setLayer = %d, want %d (SetLayerOK); stderr: %s", code, SetLayerOK, stderr.String())
	}
}

// -- pre-validation: undeclared name never dials ------------------------

// TestSetLayer_UndeclaredName_RefusedWithoutDialing is the task's core
// requirement (us019 AC4 / adr0021 at the CLI): an undeclared name must be
// refused BY NAME before any socket I/O, proven here by a listener that
// counts Accept calls -- it must stay at zero.
func TestSetLayer_UndeclaredName_RefusedWithoutDialing(t *testing.T) {
	display := ":82"
	ln := newTestCtlListener(t, display)

	var mu sync.Mutex
	accepts := 0
	stop := make(chan struct{})
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			mu.Lock()
			accepts++
			mu.Unlock()
			conn.Close()
		}
	}()
	defer close(stop)

	var stdout, stderr bytes.Buffer
	code := setLayer(externalOnly(), "not-declared-anywhere", display, setLayerTestTimeout, &stdout, &stderr)

	if code != SetLayerRefused {
		t.Fatalf("setLayer(undeclared) = %d, want %d (SetLayerRefused)", code, SetLayerRefused)
	}
	mu.Lock()
	n := accepts
	mu.Unlock()
	if n != 0 {
		t.Fatalf("dialed the socket %d time(s) for an undeclared name -- pre-validation did not short-circuit", n)
	}
	if stdout.Len() != 0 {
		t.Errorf("stdout should be empty on a pre-validation refusal, got %q", stdout.String())
	}
	msg := stderr.String()
	if !strings.Contains(msg, "not-declared-anywhere") {
		t.Errorf("refusal does not name the offending layer: %q", msg)
	}
	if strings.Contains(msg, "connect") || strings.Contains(msg, "dial") {
		t.Errorf("refusal reads like a CONNECT error, not a named pre-validation refusal: %q", msg)
	}
}

// TestSetLayer_ChordLayerName_Refused proves the pre-validation gate also
// catches a REAL layer name that just is not External-declared (chord-only
// layers stay chord-only) -- not just a name absent from the table
// entirely.
func TestSetLayer_ChordLayerName_Refused(t *testing.T) {
	layers := externalOnly()
	layers["nav"] = bind.Layer{ExitKeys: []string{"q"}}

	var stdout, stderr bytes.Buffer
	code := setLayer(layers, "nav", ":83", setLayerTestTimeout, &stdout, &stderr)

	if code != SetLayerRefused {
		t.Fatalf("setLayer(nav) = %d, want %d (SetLayerRefused)", code, SetLayerRefused)
	}
	if !strings.Contains(stderr.String(), "nav") {
		t.Errorf("refusal does not name the chord-only layer: %q", stderr.String())
	}
}

// -- default always pre-validates ---------------------------------------

// TestSetLayer_Default_PreValidatesEvenWithNoExternalLayers proves "default"
// is always accepted by pre-validation (the clear verb must stay
// unambiguous) even against a table with no External layer at all -- so
// the dial happens and the exchange proceeds.
func TestSetLayer_Default_PreValidatesEvenWithNoExternalLayers(t *testing.T) {
	display := ":84"
	ln := newTestCtlListener(t, display)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 4096)
		conn.Read(buf)
		conn.Write([]byte(`{"ok":true}` + "\n"))
	}()

	var stdout, stderr bytes.Buffer
	code := setLayer(map[string]bind.Layer{}, "default", display, setLayerTestTimeout, &stdout, &stderr)
	if code != SetLayerOK {
		t.Fatalf("setLayer(default) = %d, want %d (SetLayerOK); stderr: %s", code, SetLayerOK, stderr.String())
	}
}

// -- daemon-side refusal ---------------------------------------------------

func TestSetLayer_DaemonRefuses_ExitsRefused(t *testing.T) {
	display := ":85"
	ln := newTestCtlListener(t, display)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 4096)
		conn.Read(buf)
		conn.Write([]byte(`{"ok":false,"error":"layer: a chord-entered layer is active: \"nav\""}` + "\n"))
	}()

	var stdout, stderr bytes.Buffer
	code := setLayer(externalOnly(), "screenshot-drag", display, setLayerTestTimeout, &stdout, &stderr)

	if code != SetLayerRefused {
		t.Fatalf("setLayer(daemon-refused) = %d, want %d (SetLayerRefused)", code, SetLayerRefused)
	}
	if !strings.Contains(stderr.String(), "chord-entered layer is active") {
		t.Errorf("stderr does not carry the daemon's own refusal text: %q", stderr.String())
	}
}

// -- unreachable: no daemon, one attempt, no retry --------------------

// setLayerNoRetryBudget bounds the no-daemon case's elapsed time -- the
// same adr0014 "single attempt, no internal loop" proof
// statetail_test.go's statTailNoRetryBudget makes for state-tail.
const setLayerNoRetryBudget = 150 * time.Millisecond

func TestSetLayer_NoDaemon_ExitsUnreachableImmediately(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir) // no socket ever bound here

	var stdout, stderr bytes.Buffer
	start := time.Now()
	code := setLayer(externalOnly(), "screenshot-drag", ":86", setLayerTestTimeout, &stdout, &stderr)
	elapsed := time.Since(start)

	if code != SetLayerUnreachable {
		t.Fatalf("setLayer(no daemon) = %d, want %d (SetLayerUnreachable); stderr: %s", code, SetLayerUnreachable, stderr.String())
	}
	if elapsed > setLayerNoRetryBudget {
		t.Errorf("setLayer took %s against a missing socket (budget %s) -- looks like an internal retry loop, which adr0014 forbids", elapsed, setLayerNoRetryBudget)
	}
	if stdout.Len() != 0 {
		t.Errorf("stdout should be empty on a connect failure, got %q", stdout.String())
	}
}

// -- unreachable: malformed reply ---------------------------------------

func TestSetLayer_MalformedReply_ExitsUnreachable(t *testing.T) {
	display := ":87"
	ln := newTestCtlListener(t, display)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 4096)
		conn.Read(buf)
		conn.Write([]byte("not json at all\n"))
	}()

	var stdout, stderr bytes.Buffer
	code := setLayer(externalOnly(), "screenshot-drag", display, setLayerTestTimeout, &stdout, &stderr)

	if code != SetLayerUnreachable {
		t.Fatalf("setLayer(malformed reply) = %d, want %d (SetLayerUnreachable); stderr: %s", code, SetLayerUnreachable, stderr.String())
	}
	if !strings.Contains(stderr.String(), "malformed") {
		t.Errorf("stderr does not name the malformed reply: %q", stderr.String())
	}
}

// -- unreachable: peer closes before any reply ---------------------------

func TestSetLayer_PeerClosesBeforeReply_ExitsUnreachableNoHang(t *testing.T) {
	display := ":88"
	ln := newTestCtlListener(t, display)
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		buf := make([]byte, 4096)
		conn.Read(buf)
		conn.Close() // no reply line at all
	}()

	var stdout, stderr bytes.Buffer
	start := time.Now()
	code := setLayer(externalOnly(), "screenshot-drag", display, setLayerTestTimeout, &stdout, &stderr)
	elapsed := time.Since(start)

	if code != SetLayerUnreachable {
		t.Fatalf("setLayer(peer closed) = %d, want %d (SetLayerUnreachable); stderr: %s", code, SetLayerUnreachable, stderr.String())
	}
	if elapsed > setLayerNoRetryBudget {
		t.Errorf("setLayer took %s on an immediate peer close (budget %s) -- should fail immediately, not wait for the deadline", elapsed, setLayerNoRetryBudget)
	}
}

// -- unreachable: silent server, deadline ------------------------------

func TestSetLayer_SilentServer_ExitsUnreachableAfterDeadlineNoHang(t *testing.T) {
	display := ":89"
	ln := newTestCtlListener(t, display)
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 4096)
		conn.Read(buf)
		// Never reply. The connection is held open until the test's own
		// deadline forces it closed via t.Cleanup on the listener; the
		// CLIENT's own deadline is what must fire first.
		<-time.After(2 * time.Second)
	}()

	var stdout, stderr bytes.Buffer
	start := time.Now()
	code := setLayer(externalOnly(), "screenshot-drag", display, setLayerTestTimeout, &stdout, &stderr)
	elapsed := time.Since(start)

	if code != SetLayerUnreachable {
		t.Fatalf("setLayer(silent server) = %d, want %d (SetLayerUnreachable); stderr: %s", code, SetLayerUnreachable, stderr.String())
	}
	budget := setLayerTestTimeout + 100*time.Millisecond
	if elapsed > budget {
		t.Errorf("setLayer took %s waiting on a silent server (budget %s) -- the client-side read deadline did not fire", elapsed, budget)
	}
	if !strings.Contains(stderr.String(), "set-layer") {
		t.Errorf("stderr does not carry a set-layer-named failure: %q", stderr.String())
	}
}

// -- per-display correctness: proc.ControlPath, screen-suffix -----------

// TestSetLayer_DisplayWithScreenSuffix_SameSocketAsBare proves the verb
// resolves through proc.ControlPath, which shares NormalizeDisplay with
// LockPath/SocketPath -- so ":10.0" and ":10" address the identical ctl
// socket (us019 AC3's per-session scoping, at the CLI).
func TestSetLayer_DisplayWithScreenSuffix_SameSocketAsBare(t *testing.T) {
	ln := newTestCtlListener(t, ":90")
	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 4096)
		conn.Read(buf)
		conn.Write([]byte(`{"ok":true}` + "\n"))
	}()

	var stdout, stderr bytes.Buffer
	code := setLayer(externalOnly(), "screenshot-drag", ":90.0", setLayerTestTimeout, &stdout, &stderr)
	if code != SetLayerOK {
		t.Fatalf("setLayer(display :90.0) = %d, want %d (SetLayerOK) -- did not resolve to :90's socket; stderr: %s", code, SetLayerOK, stderr.String())
	}
}

// -- runSetLayerCmd: argv / $DISPLAY resolution --------------------------

// TestRunSetLayerCmd_NoArgs_UsageExitTwo pins the flag-parse convention:
// missing the required NAME argument is a usage error, not a refusal or an
// unreachable-socket error.
func TestRunSetLayerCmd_NoArgs_UsageExitTwo(t *testing.T) {
	code, stderr := captureStderr(t, func() int {
		return runSetLayerCmd(nil)
	})
	if code != 2 {
		t.Fatalf("runSetLayerCmd(nil) = %d, want 2", code)
	}
	if !strings.Contains(stderr, "set-layer") {
		t.Errorf("usage output does not mention set-layer: %q", stderr)
	}
}

// TestRunSetLayerCmd_DisplayFlag_ResolvesLikeControlPath proves --display
// (not just the leading positional NAME) actually reaches proc.ControlPath,
// exercised through the REAL entry point (argv, os.Stdout/os.Stderr, and
// the package's real `Layers`) -- using name "default", the one name
// pre-validation accepts regardless of what config.go's shipped table
// declares (Task 5, not this task, adds the first real External layer), so
// a dial genuinely happens and reaches THIS display's listener specifically.
func TestRunSetLayerCmd_DisplayFlag_ResolvesLikeControlPath(t *testing.T) {
	ln := newTestCtlListener(t, ":91")
	var wg sync.WaitGroup
	wg.Add(1)
	go func() {
		defer wg.Done()
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 4096)
		conn.Read(buf)
		conn.Write([]byte(`{"ok":true}` + "\n"))
	}()

	code, stderr := captureStderr(t, func() int {
		return runSetLayerCmd([]string{"default", "--display", ":91"})
	})
	wg.Wait()

	if code != SetLayerOK {
		t.Fatalf("runSetLayerCmd([default, --display, :91]) = %d, want %d (SetLayerOK); stderr: %q", code, SetLayerOK, stderr)
	}
}
