package main

// sp012 Task 7 (kwi3-hoex.7): `hotkeyd recover`, the Windows half of the
// panic chord ([[adr0003]]/[[adr0021]] amendments 2026-10-26). The Win32
// host runs it (kwi3-hoex.8) and waits; a non-zero exit makes the HOST give
// every window back and exit. The sequence, each step said on stderr:
//
//  1. release every modifier Windows reports held: GetAsyncKeyState per
//     sided modifier VK, and for each one held, ONE SendInput key-up of
//     that VK - adr0021's amended second case of synthetic input, and
//     nothing else is ever sent. Nothing held: nothing sent.
//  2. stop the running daemon - the pid its lock names, and only while that
//     lock is really held: a {"stop":true} on its control socket, then up
//     to 2 s for the process to exit; one that has not is ended BY PID
//     (TerminateProcess on a handle opened before the stop, so the pid
//     cannot have been reused in between), never by name, and that is
//     logged. No daemon: nothing to stop.
//  3. start a new one, detached, with the old one's arguments (the record
//     runWin32 writes beside its lock, <desktop>.args).
//  4. exit 0 once --health says it serves, 1 if it does not - the last
//     verdict printed, naming the first check that failed.
//
// The whole run shares ONE deadline, recoverBudget from its start
// (kwi3-hoex.21): the stop request, both waits and every health poll get
// what is left of it, each at most its own bound, so a stuck daemon and a
// new one that never serves still answer inside 12 s - before the host's
// 15 s I3KWIN_RECOVER_TIMEOUT_MS, so the host hears recover's own verdict
// rather than timing it out.
//
// Pure over recoverDeps: recover_test.go drives every branch with fakes on
// Linux; recover_windows.go wires the real ones.

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	"hotkeyd/internal/kwi3rpc"
	"hotkeyd/internal/proc"
	"hotkeyd/internal/win32"
)

const (
	// recoverBudget bounds the whole of `hotkeyd recover`, worst case.
	recoverBudget   = 12 * time.Second
	recoverStopWait = 2 * time.Second
	recoverPoll     = 250 * time.Millisecond
	// recoverControlTimeout bounds one stop or status request.
	recoverControlTimeout = time.Second
	// kwi3ProbeTimeout bounds a status request's kwi3rpc round trip.
	kwi3ProbeTimeout = 2 * time.Second
	// healthPollTimeout bounds one --health status request: the daemon's
	// own kwi3rpc probe plus the control round trip.
	healthPollTimeout = kwi3ProbeTimeout + recoverControlTimeout
)

// recoverModifiers is every sided modifier VK recover asks about, in the
// order it releases them.
var recoverModifiers = []struct {
	vk   uint16
	name string
}{
	{win32.VK_LSHIFT, "LShift"}, {win32.VK_RSHIFT, "RShift"},
	{win32.VK_LCONTROL, "LCtrl"}, {win32.VK_RCONTROL, "RCtrl"},
	{win32.VK_LMENU, "LAlt"}, {win32.VK_RMENU, "RAlt"},
	{win32.VK_LWIN, "LWin"}, {win32.VK_RWIN, "RWin"},
}

// argsRecord is what a Windows daemon writes beside its lock: its pid, its
// arguments, and the environment it was started with that selects what it
// does ($KWI3SOCK, HOTKEYD_WIN32_DRYRUN). recover starts the new daemon
// with the same.
type argsRecord struct {
	PID  int               `json:"pid"`
	Args []string          `json:"args"`
	Env  map[string]string `json:"env,omitempty"`
}

// recordedEnv is the environment an argsRecord carries.
var recordedEnv = []string{"KWI3SOCK", win32DryRunEnvName}

// win32DryRunEnvName is HOTKEYD_WIN32_DRYRUN, spelled here too so the pure
// files do not need win32run.go's Windows-only constant.
const win32DryRunEnvName = "HOTKEYD_WIN32_DRYRUN"

// argsPath is <desktop>.args beside the lock.
func argsPath(display string) string {
	return strings.TrimSuffix(proc.LockPath(display), ".lock") + ".args"
}

// writeArgsRecord records this process's arguments and selecting
// environment for a later recover. Best-effort: a daemon that cannot
// write it still serves; recover then starts the new one with none.
func writeArgsRecord(display string, args []string, getenv func(string) string) error {
	rec := argsRecord{PID: os.Getpid(), Args: args, Env: map[string]string{}}
	if rec.Args == nil {
		rec.Args = []string{}
	}
	for _, k := range recordedEnv {
		if v := getenv(k); v != "" {
			rec.Env[k] = v
		}
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	return os.WriteFile(argsPath(display), data, 0o644)
}

// readArgsRecord reads <desktop>.args.
func readArgsRecord(display string) (argsRecord, bool) {
	data, err := os.ReadFile(argsPath(display))
	if err != nil {
		return argsRecord{}, false
	}
	var rec argsRecord
	if err := json.Unmarshal(data, &rec); err != nil {
		return argsRecord{}, false
	}
	return rec, true
}

// childEnv is base with the record's environment laid over it. A recorded
// value only ever SETS: a dry-run recover keeps its own
// HOTKEYD_WIN32_DRYRUN=1 even when the old daemon was not started with it,
// so a test can never turn into a daemon that registers chords.
func childEnv(base []string, rec argsRecord) []string {
	out := append([]string(nil), base...)
	for _, k := range recordedEnv {
		v, ok := rec.Env[k]
		if !ok {
			continue
		}
		if k == win32DryRunEnvName && strings.TrimSpace(envValue(out, k)) == "1" {
			continue
		}
		out = setEnv(out, k, v)
	}
	return out
}

// envValue is key's value in env ("" if absent). Windows environment names
// are case-insensitive, so the match is too.
func envValue(env []string, key string) string {
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		if strings.EqualFold(k, key) {
			return v
		}
	}
	return ""
}

// setEnv is env with every key entry replaced by one key=value.
func setEnv(env []string, key, value string) []string {
	out := env[:0:0]
	for _, kv := range env {
		k, _, _ := strings.Cut(kv, "=")
		if !strings.EqualFold(k, key) {
			out = append(out, kv)
		}
	}
	return append(out, key+"="+value)
}

// kwi3ProbeFor is a status request's kwi3rpc check: one workspace.list
// round trip to sock on a connection of its own, bounded by
// kwi3ProbeTimeout. An *RPCError is still an answer - the connection is
// up - so only a transport failure is an error.
func kwi3ProbeFor(sock string) func() error {
	return func() error {
		c := kwi3rpc.New(sock, kwi3rpc.WithCallTimeout(kwi3ProbeTimeout))
		defer c.Close()
		_, err := c.Call("workspace.list", nil)
		var rpcErr *kwi3rpc.RPCError
		if err == nil || errors.As(err, &rpcErr) {
			return nil
		}
		return err
	}
}

// recoverProc is a handle on the old daemon's process, opened by pid.
type recoverProc interface {
	// Wait reports whether the process exited within d.
	Wait(d time.Duration) bool
	// Terminate ends the process this handle was opened on.
	Terminate() error
	Close()
}

// recoverChild is the new daemon recover started.
type recoverChild interface {
	PID() int
	// Exited reports the exit code once the child has exited.
	Exited() (code int, done bool)
}

// recoverDeps is recover's I/O seam set.
type recoverDeps struct {
	display string
	// dryRun: say which key-ups would be sent, send none
	// (HOTKEYD_WIN32_DRYRUN=1 - a test run of the real binary).
	dryRun   bool
	keyDown  func(vk uint16) bool
	keyUp    func(vk uint16) error
	lockPID  func(path string) (int, bool)
	lockHeld func(path string) bool
	openProc func(pid int) (recoverProc, error)
	// stop sends {"stop":true}, the request bounded by timeout.
	stop     func(controlPath string, timeout time.Duration) error
	readArgs func(display string) (argsRecord, bool)
	start    func(rec argsRecord) (recoverChild, error)
	// health is one --health verdict, its status request bounded by
	// timeout.
	health func(display string, timeout time.Duration) (int, string)
	now    func() time.Time
	sleep  func(time.Duration)
	log    func(string)
	out    io.Writer
}

// recoverDeadline is the one deadline a recover run shares.
type recoverDeadline struct {
	at  time.Time
	now func() time.Time
}

// left is what remains of the budget, never negative.
func (b recoverDeadline) left() time.Duration {
	if l := b.at.Sub(b.now()); l > 0 {
		return l
	}
	return 0
}

// clamp is bound, cut to what remains of the budget.
func (b recoverDeadline) clamp(bound time.Duration) time.Duration {
	if l := b.left(); l < bound {
		return l
	}
	return bound
}

// releaseModifiers is step 1: one key-up for each sided modifier held,
// nothing for one that is not. Returns how many were released.
func releaseModifiers(d recoverDeps) int {
	n := 0
	for _, m := range recoverModifiers {
		if !d.keyDown(m.vk) {
			continue
		}
		n++
		if d.dryRun {
			d.log(fmt.Sprintf("recover: %s is held; DRY RUN, no key-up sent", m.name))
			continue
		}
		if err := d.keyUp(m.vk); err != nil {
			d.log(fmt.Sprintf("recover: %s is held; its key-up failed: %s", m.name, err))
			continue
		}
		d.log(fmt.Sprintf("recover: %s was held; released it (one SendInput key-up)", m.name))
	}
	if n == 0 {
		d.log("recover: no modifier held; nothing sent")
	}
	return n
}

// recoverRun is `hotkeyd recover`: the exit code, 0 serving, 1 not.
func recoverRun(d recoverDeps) int {
	disp := resolveDisplay(d.display)
	budget := recoverDeadline{at: d.now().Add(recoverBudget), now: d.now}
	releaseModifiers(d)

	lockPath := proc.LockPath(disp)
	oldPID, named := d.lockPID(lockPath)
	switch {
	case named && d.lockHeld(lockPath):
		if code, ok := stopDaemon(d, budget, disp, oldPID); !ok {
			return code
		}
	case named:
		d.log(fmt.Sprintf("recover: %s names pid %d, which no longer holds it; nothing to stop", lockPath, oldPID))
	default:
		d.log(fmt.Sprintf("recover: no daemon running on %s; starting one", disp))
	}

	rec, ok := d.readArgs(disp)
	if !ok {
		d.log(fmt.Sprintf("recover: no record of the old daemon's arguments (%s); starting with none", argsPath(disp)))
		rec = argsRecord{}
	}
	child, err := d.start(rec)
	if err != nil {
		fmt.Fprintf(d.out, "hotkeyd recover: %s — cannot start a new daemon: %s\n", disp, err)
		return 1
	}
	d.log(fmt.Sprintf("recover: started pid %d with arguments %q", child.PID(), rec.Args))

	// verdict is the last health verdict; full is the last one whose poll
	// had its whole healthPollTimeout. A poll cut short by the budget can
	// time out on the control socket while the daemon is still asking
	// kwi3 - "control:" then names the wrong check, so the full poll's
	// verdict is said beside it.
	verdict, full := "no health poll fit in the budget", ""
	fail := func(why string) int {
		if full != "" && full != verdict {
			why += " (the last poll was cut short by the budget; the one before it, with its full time: " + full + ")"
		}
		fmt.Fprintf(d.out, "hotkeyd recover: %s — %s\n", disp, why)
		return 1
	}
	for {
		timeout := budget.clamp(healthPollTimeout)
		if timeout <= 0 {
			return fail(fmt.Sprintf("not serving within the %s budget: %s", recoverBudget, verdict))
		}
		code, msg := d.health(disp, timeout)
		if code == HealthOK {
			if pid, _ := d.lockPID(lockPath); pid == child.PID() {
				fmt.Fprintln(d.out, msg)
				return 0
			}
		}
		if timeout == healthPollTimeout {
			full = msg
		}
		verdict = msg
		if exit, done := child.Exited(); done {
			return fail(fmt.Sprintf("the new daemon (pid %d) exited with code %d; last verdict: %s", child.PID(), exit, verdict))
		}
		if budget.left() <= 0 {
			return fail(fmt.Sprintf("not serving within the %s budget: %s", recoverBudget, verdict))
		}
		d.sleep(budget.clamp(recoverPoll))
	}
}

// stopDaemon is step 2. ok=false means recover must exit with code.
func stopDaemon(d recoverDeps, budget recoverDeadline, disp string, pid int) (code int, ok bool) {
	p, err := d.openProc(pid)
	if err != nil {
		fmt.Fprintf(d.out, "hotkeyd recover: %s — the lock is held by pid %d, which cannot be opened: %s\n", disp, pid, err)
		return 1, false
	}
	defer p.Close()
	if err := d.stop(proc.ControlPath(disp), budget.clamp(recoverControlTimeout)); err != nil {
		d.log(fmt.Sprintf("recover: pid %d: the control socket's stop failed: %s", pid, err))
	}
	wait := budget.clamp(recoverStopWait)
	if p.Wait(wait) {
		d.log(fmt.Sprintf("recover: pid %d stopped on the control socket's stop", pid))
		return 0, true
	}
	d.log(fmt.Sprintf("recover: pid %d did not exit within %s of the stop; ending it BY PID (TerminateProcess on pid %d, never by name)",
		pid, wait, pid))
	if err := p.Terminate(); err != nil {
		fmt.Fprintf(d.out, "hotkeyd recover: %s — TerminateProcess on pid %d failed: %s\n", disp, pid, err)
		return 1, false
	}
	if !p.Wait(budget.clamp(recoverStopWait)) {
		fmt.Fprintf(d.out, "hotkeyd recover: %s — pid %d is still running after TerminateProcess\n", disp, pid)
		return 1, false
	}
	d.log(fmt.Sprintf("recover: pid %d ended by pid", pid))
	return 0, true
}
