package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// DaemonRig starts and observes the REAL Go daemon binary as a subprocess.
//
// # The sandbox HOME, and why the shipped table can be driven safely
//
// live_check.py drives the daemon with a stand-in bind table for the
// switcher scenarios, because the shipped table's switcher actions `run()`
// qs-overlay.sh and "a live check must not spawn the user's shell scripts to
// prove the engine wiring". The Go daemon has no --binds flag at all — the
// table is compiled in (the dwm model) — so the substitution moves from the
// table to the environment: HOME points at a scratch tree containing STUBS
// at exactly the paths the shipped table names, and proc.Run executes every
// Run action through `/bin/sh -c`, where `~` expands against the child's
// HOME. The operator's own scripts are never reachable, and each stub
// appends its argv to a log, so which action fired is directly observable —
// the same evidence live_check.py's RecordingI3 collects, for the half of
// the table that is Run rather than i3 Command.
type DaemonRig struct {
	Bin        []string
	Display    string
	RuntimeDir string
	HomeDir    string
	ActionLog  string

	cmd   *exec.Cmd
	Log   *logSink
	State *StateWatcher
	Proxy *I3Proxy
}

// stubScript is what every shipped Run target is replaced by inside the
// sandbox HOME: it records its own path and argv and exits 0.
const stubScript = `#!/bin/sh
printf '%s %s\n' "$(basename "$0")" "$*" >> "$HOTKEYD_LIVECHECK_ACTIONS"
exit 0
`

// shippedRunTargets are the paths the compiled-in table's Run actions name,
// relative to HOME. Every one gets a stub; a Run action that escaped the
// sandbox would fail loudly (no such file) rather than silently running the
// operator's script.
var shippedRunTargets = []string{
	".dotfiles/quickshell/qs-overlay.sh",
	".dotfiles/quickshell/qs-screenshot.sh",
	".dotfiles/quickshell/qs-notif.sh",
	".dotfiles/quickshell/qs-clip.sh",
	".local/bin/ws-switch.nu",
	".local/bin/wm-launch-terminal",
	".local/bin/i3exit",
}

// NewDaemonRig prepares the sandbox but starts nothing.
func NewDaemonRig(bin []string, display, runtimeDir string) (*DaemonRig, error) {
	home, err := os.MkdirTemp("", "hkl-home-")
	if err != nil {
		return nil, err
	}
	actions := filepath.Join(home, "actions.log")
	for _, rel := range shippedRunTargets {
		p := filepath.Join(home, rel)
		if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
			return nil, err
		}
		if err := os.WriteFile(p, []byte(stubScript), 0o755); err != nil {
			return nil, err
		}
	}
	if err := os.WriteFile(actions, nil, 0o644); err != nil {
		return nil, err
	}
	return &DaemonRig{
		Bin: bin, Display: display, RuntimeDir: runtimeDir,
		HomeDir: home, ActionLog: actions,
	}, nil
}

// Start launches the daemon and waits for its startup grab-summary line.
// i3Sock, when non-empty, is handed to the daemon as $HOTKEYD_I3SOCK.
func (d *DaemonRig) Start(i3Sock string, timeout time.Duration) error {
	if len(d.Bin) == 0 {
		return fmt.Errorf("livecheck: no daemon binary configured")
	}
	d.Log = &logSink{}
	cmd := exec.Command(d.Bin[0], append(append([]string{}, d.Bin[1:]...), "--display", d.Display)...)
	env := childEnv(os.Environ(), d.Display, d.HomeDir)
	env = append(env,
		"XDG_RUNTIME_DIR="+d.RuntimeDir,
		"HOTKEYD_LIVECHECK_ACTIONS="+d.ActionLog,
		// PATH keeps the sandbox's bin first so a bare-command action
		// (`i3exit ...`) resolves to the stub, never to a real one.
		"PATH="+filepath.Join(d.HomeDir, ".local", "bin")+":"+os.Getenv("PATH"),
	)
	if i3Sock != "" {
		env = append(env, "HOTKEYD_I3SOCK="+i3Sock)
	}
	cmd.Env = env
	cmd.Stdout = d.Log
	cmd.Stderr = d.Log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("livecheck: starting %v: %w", d.Bin, err)
	}
	d.cmd = cmd

	if _, ok := d.Log.Await(func(l string) bool {
		_, _, ok := parseGrabSummary(l)
		return ok
	}, timeout); !ok {
		d.Stop()
		return fmt.Errorf("livecheck: daemon never reported its grab set within %s; log:\n%s",
			timeout, strings.Join(d.Log.Lines(), "\n"))
	}
	return nil
}

// GrabSummary returns the chord count and $mod the daemon announced.
func (d *DaemonRig) GrabSummary() (int, string, bool) {
	for _, l := range d.Log.Lines() {
		if n, mod, ok := parseGrabSummary(l); ok {
			return n, mod, true
		}
	}
	return 0, "", false
}

// Actions returns every stubbed Run action recorded since the last
// ResetActions.
//
// IT RETURNS NIL WHEN THE LOG CANNOT BE READ, which makes it unsafe for any
// claim whose PASS condition is an EMPTY action list: "the daemon dispatched
// nothing" and "this observer could not look" come back as the same value —
// the helper's failure mode equalling its pass condition. Callers grading an
// ABSENCE must use ActionsOK and gate on the read having succeeded.
func (d *DaemonRig) Actions() []string {
	acts, _ := d.ActionsOK()
	return acts
}

// ActionsOK is Actions with the read's own success reported separately, so an
// unreadable action log is distinguishable from a silent daemon.
func (d *DaemonRig) ActionsOK() ([]string, bool) {
	b, err := os.ReadFile(d.ActionLog)
	if err != nil {
		return nil, false
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		if s := strings.TrimSpace(l); s != "" {
			out = append(out, s)
		}
	}
	return out, true
}

func (d *DaemonRig) ResetActions() { _ = os.WriteFile(d.ActionLog, nil, 0o644) }

// AwaitAction waits for a recorded action containing want.
func (d *DaemonRig) AwaitAction(want string, timeout time.Duration) ([]string, bool) {
	deadline := time.Now().Add(timeout)
	for {
		got := d.Actions()
		for _, a := range got {
			if strings.Contains(a, want) {
				return got, true
			}
		}
		if time.Now().After(deadline) {
			return got, false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// Stop sends SIGTERM and waits for the process to exit.
func (d *DaemonRig) Stop() int {
	if d.cmd == nil || d.cmd.Process == nil {
		return -1
	}
	_ = d.cmd.Process.Signal(syscall.SIGTERM)
	done := make(chan error, 1)
	go func() { done <- d.cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = d.cmd.Process.Kill()
		<-done
	}
	code := d.cmd.ProcessState.ExitCode()
	d.cmd = nil
	return code
}

func (d *DaemonRig) Cleanup() {
	if d.cmd != nil {
		d.Stop()
	}
	if d.State != nil {
		d.State.Close()
	}
	_ = os.RemoveAll(d.HomeDir)
}

// RunOnce runs the daemon binary to completion with the given extra args
// and returns its exit code plus combined output. Used for the
// single-instance check, where the SECOND daemon is expected to die at once.
func (d *DaemonRig) RunOnce(timeout time.Duration, args ...string) (int, string) {
	cmd := exec.Command(d.Bin[0], append(append([]string{}, d.Bin[1:]...), args...)...)
	cmd.Env = append(childEnv(os.Environ(), d.Display, d.HomeDir),
		"XDG_RUNTIME_DIR="+d.RuntimeDir,
		"HOTKEYD_LIVECHECK_ACTIONS="+d.ActionLog)
	var sink logSink
	cmd.Stdout = &sink
	cmd.Stderr = &sink
	if err := cmd.Start(); err != nil {
		return -1, err.Error()
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		<-done
		return -2, "timed out: " + strings.Join(sink.Lines(), "\n")
	}
	return cmd.ProcessState.ExitCode(), strings.Join(sink.Lines(), "\n")
}
