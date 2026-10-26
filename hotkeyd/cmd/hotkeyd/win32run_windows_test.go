package main

// sp012 Task 4 (kwi3-hoex.4): `--input win32` assembled (startWin32) on
// real Windows - the real hotkey thread and message-only window, the real
// daemon loop and engine, and a WM_HOTKEY posted to the daemon's window.
// Run through hotkeyd/test-win32.sh (the "_Windows_" name is its filter).
//
// SAFETY: every test here runs the thread with DryRun, so NOTHING is
// registered: registrations are shared by every desktop of the window
// station (kwi3-hoex.8), and a test must not take Jan's Alt chords. A
// posted WM_HOTKEY proves the handler and the dispatch, never key
// delivery - that is attended (kwi3-hoex.14/.17).

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/kwi3rpc"
	"hotkeyd/internal/proc"
	"hotkeyd/internal/win32"
)

var procPostMessage = syscall.NewLazyDLL("user32.dll").NewProc("PostMessageW")

func procPostMessageW(hwnd uintptr, msg uint32, w, l uintptr) error {
	if r, _, err := procPostMessage.Call(hwnd, uintptr(msg), w, l); r == 0 {
		return err
	}
	return nil
}

// smallTable is $mod+2 -> kwi3's workspace 2, what host_win32.go's
// workspace overrides send.
var smallTable = []bind.Bind{
	{Chord: "$mod+2", Actions: cmdAction("workspace 2")},
	{Chord: "$mod+1", Actions: cmdAction("workspace 1")},
}

func startDryRunDaemon(t *testing.T, kwi3Sock string, mkdir bool) (*Daemon, *win32.Source, chan os.Signal, chan int) {
	t.Helper()
	return startDryRunDaemonWith(t, kwi3Sock, mkdir, smallTable, map[string]bind.Layer{})
}

func startDryRunDaemonWith(t *testing.T, kwi3Sock string, mkdir bool, binds []bind.Bind, layers map[string]bind.Layer) (*Daemon, *win32.Source, chan os.Signal, chan int) {
	t.Helper()
	display := fmt.Sprintf("hk-test-%d", os.Getpid())
	if mkdir {
		if err := os.MkdirAll(proc.RuntimeDir(), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	dae, src, err := startWin32(win32Config{
		Display:  display,
		Kwi3Sock: kwi3Sock,
		Binds:    binds,
		Layers:   layers,
		Source:   win32.Options{DryRun: true},
		Log:      func(s string) { t.Log(s) },
	})
	if err != nil {
		t.Fatalf("startWin32: %s", err)
	}
	sig := make(chan os.Signal, 1)
	done := make(chan int, 1)
	go func() { done <- dae.Run(sig) }()
	t.Cleanup(func() {
		select {
		case sig <- os.Interrupt:
		default:
		}
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("daemon did not stop")
		}
	})
	return dae, src, sig, done
}

func postAltDigit(t *testing.T, src *win32.Source, digit byte) {
	t.Helper()
	if err := procPostMessageW(src.Window(), win32.WM_HOTKEY, 1, uintptr(win32.MOD_ALT)|uintptr(digit)<<16); err != nil {
		t.Fatalf("PostMessageW(WM_HOTKEY): %s", err)
	}
}

// A WM_HOTKEY for Alt+2 posted to the daemon's window reaches kwi3 as
// workspace.focus {num: 2}; the registered set is the table, all
// "granted" (DryRun), and the daemon stops cleanly.
func TestWin32Run_Windows_PostedHotkeyDispatches(t *testing.T) {
	modes := newModeServer(t, false)
	dae, src, sig, done := startDryRunDaemon(t, modes.addr, true)
	if w, a, m := dae.grabs.GrabReport(); w != 2 || a != 2 || len(m) != 0 {
		t.Fatalf("grab report %d %d %q", w, a, m)
	}
	t.Logf("daemon window %#x", src.Window())
	postAltDigit(t, src, '2')
	got := ""
	waitFor(t, "workspace.focus reaches kwi3", func() bool {
		for _, r := range modes.got() {
			if strings.HasPrefix(r, "workspace.focus") {
				got = r
				return true
			}
		}
		return false
	})
	t.Logf("kwi3 received %q", got)
	if got != "workspace.focus " {
		// modeServer records params.name; a position goes as num, no name.
		t.Errorf("kwi3 received %q, want workspace.focus by num (no name)", got)
	}
	sig <- os.Interrupt
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
		done <- code // for the cleanup
	case <-time.After(5 * time.Second):
		t.Fatal("daemon did not stop")
	}
}

// With %LOCALAPPDATA%\hotkeyd missing (no state feed, no control socket)
// the daemon still serves and stops cleanly - a nil publisher must not
// reach shutdown as a typed-nil Closer.
func TestWin32Run_Windows_NoRuntimeDirStillServes(t *testing.T) {
	t.Setenv("LOCALAPPDATA", filepath.Join(t.TempDir(), "absent"))
	modes := newModeServer(t, false)
	_, src, sig, done := startDryRunDaemon(t, modes.addr, false)
	postAltDigit(t, src, '1')
	waitFor(t, "workspace.focus reaches kwi3", func() bool {
		for _, r := range modes.got() {
			if strings.HasPrefix(r, "workspace.focus") {
				return true
			}
		}
		return false
	})
	sig <- os.Interrupt
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("exit %d", code)
		}
		done <- code
	case <-time.After(5 * time.Second):
		t.Fatal("daemon did not stop")
	}
}

// The end-to-end half of the criterion, against a REAL i3kwin-win32 on a
// rig desktop: HOTKEYD_E2E_PIPE names its pipe. The daemon runs the
// shipped (-tags win32) table, DryRun, dispatches a posted Alt+2, and the
// host's tree.get then has workspace 2 focused.
// Skipped without the variable (the rig script sets it).
func TestWin32Run_Windows_E2E_HostFocusesWorkspace2(t *testing.T) {
	pipe := os.Getenv("HOTKEYD_E2E_PIPE")
	if pipe == "" {
		t.Skip("HOTKEYD_E2E_PIPE not set: no host to drive")
	}
	// The shipped table, as this binary was built: only a -tags win32
	// build sends $mod+2 to kwi3 (host_win32.go); the Linux table runs
	// ws-switch.nu, which Windows does not have.
	binds := effectiveBinds(pipe)
	is := false
	for _, b := range binds {
		if b.Chord == "$mod+2" && len(b.Actions) == 1 {
			_, is = b.Actions[0].(bind.Command)
		}
	}
	if !is {
		t.Skip("this build's $mod+2 is not a kwi3 command: build the test binary with -tags win32")
	}
	client := kwi3rpc.New(pipe)
	defer client.Close()
	before, err := focusedWorkspaceNum(client)
	if err != nil {
		t.Fatalf("tree.get before: %s", err)
	}
	t.Logf("before: workspace %d focused", before)
	if before == 2 {
		t.Fatal("workspace 2 is already focused; the test would prove nothing")
	}
	_, src, _, _ := startDryRunDaemonWith(t, pipe, true, binds, Layers)
	postAltDigit(t, src, '2')
	var now int
	defer func() {
		if t.Failed() {
			ws, err := client.Call("workspace.list", nil)
			tree, _ := client.Call("tree.get", nil)
			t.Logf("workspace.list: %s (err %v); last tree.get read %d\ntree.get: %s", ws, err, now, tree)
		}
	}()
	waitForLong(t, "the host focuses workspace 2", func() bool {
		now, err = focusedWorkspaceNum(client)
		return err == nil && now == 2
	})
	t.Logf("after the posted Alt+2: workspace %d focused (tree.get)", now)
	postAltDigit(t, src, '1')
	waitForLong(t, "back on workspace 1", func() bool {
		now, err = focusedWorkspaceNum(client)
		return err == nil && now == 1
	})
}

func waitForLong(t *testing.T, what string, ok func() bool) {
	t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		if ok() {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	t.Fatalf("timed out: %s", what)
}

// focusedWorkspaceNum reads tree.get: the workspace that holds the con
// marked focused (the workspace con itself when it is empty). Not the
// focus order: kwi3's content con lists its workspaces' focus in tree
// order, so focus[0] there need not be the focused one (measured here).
func focusedWorkspaceNum(c *kwi3rpc.Client) (int, error) {
	raw, err := c.Call("tree.get", nil)
	if err != nil {
		return 0, err
	}
	var root treeCon
	if err := json.Unmarshal(raw, &root); err != nil {
		return 0, err
	}
	num, found := 0, 0
	var visit func(n *treeCon, ws *treeCon)
	visit = func(n *treeCon, ws *treeCon) {
		if n.Type == "workspace" {
			ws = n
		}
		if n.Focused && ws != nil {
			num = ws.Num
			found++
		}
		for i := range n.Nodes {
			visit(&n.Nodes[i], ws)
		}
	}
	visit(&root, nil)
	if found != 1 {
		return 0, fmt.Errorf("tree.get has %d focused con(s) inside a workspace, want 1", found)
	}
	return num, nil
}

type treeCon struct {
	Type    string    `json:"type"`
	Num     int       `json:"num"`
	Focused bool      `json:"focused"`
	Nodes   []treeCon `json:"nodes"`
}
