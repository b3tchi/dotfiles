package main

// sp012 Task 7 (kwi3-hoex.7): the control socket's status and stop
// requests, the Windows --health verdict with each check failing in turn,
// and `hotkeyd recover`'s sequence - all over fakes, on any OS. The real
// Windows wiring is recover_windows_test.go's.

import (
	"bufio"
	"errors"
	"net"
	"os"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"hotkeyd/internal/layer"
	"hotkeyd/internal/proc"
	"hotkeyd/internal/win32"
)

// controlIntoRun wires a real ControlListener into a harness's real Run
// loop, the way startup does.
func controlIntoRun(t *testing.T, probe func() error) (*harness, string, chan int, chan os.Signal) {
	t.Helper()
	h := newHarness(t)
	logger := &fakeLogger{}
	dir, err := os.MkdirTemp("", "hk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	l, err := NewControlListener(ControlConfig{Path: dir + "/c.sock", Log: logger.log, Kwi3Probe: probe})
	if err != nil {
		t.Fatalf("NewControlListener: %v", err)
	}
	t.Cleanup(func() { _ = l.Close() })
	go func() {
		for cmd := range l.Commands() {
			h.control <- cmd
		}
	}()
	sig := make(chan os.Signal, 1)
	done := make(chan int, 1)
	go func() { done <- h.dae.Run(sig) }()
	t.Cleanup(func() {
		select {
		case sig <- syscall.SIGTERM:
		default:
		}
		select {
		case <-done:
		case <-time.After(2 * time.Second):
		}
	})
	return h, l.Path(), done, sig
}

func TestControl_Status_AnsweredByRunLoopWithGrabsAndKwi3(t *testing.T) {
	h, path, _, _ := controlIntoRun(t, func() error { return nil })
	h.grabs.mu.Lock()
	h.grabs.grabReportWanted, h.grabs.grabReportActive = 5, 4
	h.grabs.grabReportMissing = []string{"$mod+x: refused"}
	h.grabs.mu.Unlock()

	rep, err := controlStatusAt(path, 2*time.Second)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if !rep.OK || rep.PID != os.Getpid() || rep.Layer != layer.DefaultLayer {
		t.Fatalf("status = %+v, want ok, pid %d, layer %q", rep, os.Getpid(), layer.DefaultLayer)
	}
	if rep.Wanted != 5 || rep.Active != 4 || len(rep.Missing) != 1 || rep.Missing[0] != "$mod+x: refused" {
		t.Fatalf("status grabs = %d/%d %v, want the key source's report 5/4 [$mod+x: refused]", rep.Active, rep.Wanted, rep.Missing)
	}
	if rep.Kwi3 != "up" {
		t.Fatalf("status kwi3 = %q, want up", rep.Kwi3)
	}
}

func TestControl_Status_Kwi3DownCarriesTheError(t *testing.T) {
	_, path, _, _ := controlIntoRun(t, func() error { return errors.New("dial \\\\.\\pipe\\nope: file not found") })
	rep, err := controlStatusAt(path, 2*time.Second)
	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if !strings.Contains(rep.Kwi3, "file not found") {
		t.Fatalf("status kwi3 = %q, want the probe's error", rep.Kwi3)
	}
}

func TestControl_Status_NoProbeLeavesKwi3Empty(t *testing.T) {
	_, path, _, _ := controlIntoRun(t, nil)
	rep, err := controlStatusAt(path, 2*time.Second)
	if err != nil || !rep.OK {
		t.Fatalf("status = %+v, %v", rep, err)
	}
	if rep.Kwi3 != "" {
		t.Fatalf("status kwi3 = %q with no probe, want empty", rep.Kwi3)
	}
}

func TestControl_Stop_RepliesThenRunShutsDownCleanly(t *testing.T) {
	h, path, done, _ := controlIntoRun(t, nil)
	tr := true
	rep, err := controlCall(path, controlRequest{Stop: &tr}, 2*time.Second)
	if err != nil || !rep.OK {
		t.Fatalf("stop = %+v, %v; want ok", rep, err)
	}
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("Run returned %d after stop, want 0", code)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not return after a stop request")
	}
	if !h.ctlCloser.wasClosed() {
		t.Fatal("stop did not run shutdown (the control closer was never closed)")
	}
	if !h.logger.contains("stop requested") {
		t.Fatalf("stop not logged; log: %v", h.logger.all())
	}
}

func TestControl_RequestNamingTwoKindsIsRefused(t *testing.T) {
	l, _, path := newTestControl(t, testControlTimeout)
	serveControl(t, l, func(string) error { return nil })
	rep, err := request(t, path, "{\"set_layer\":\"x\",\"stop\":true}\n")
	if err != nil {
		t.Fatal(err)
	}
	if rep.OK || !strings.Contains(rep.Error, "more than one") {
		t.Fatalf("reply = %+v, want refused naming more than one kind", rep)
	}
}

func TestControl_SetLayerReplyCarriesNoStatusFields(t *testing.T) {
	l, _, path := newTestControl(t, testControlTimeout)
	serveControl(t, l, func(string) error { return nil })
	conn, err := dialRaw(path, setLayerLine("x"))
	if err != nil {
		t.Fatal(err)
	}
	if conn != "{\"ok\":true}" {
		t.Fatalf("set-layer reply = %s, want exactly {\"ok\":true}", conn)
	}
}

// -- the Windows --health verdict --------------------------------------------

type fakeWinHealth struct {
	pid      int
	pidKnown bool
	alive    bool
	status   controlReply
	stErr    error
}

func (f fakeWinHealth) probes() win32HealthProbes {
	return win32HealthProbes{
		lockPID:  func(string) (int, bool) { return f.pid, f.pidKnown },
		pidAlive: func(pid int) bool { return f.alive && pid == f.pid },
		status:   func(string) (controlReply, error) { return f.status, f.stErr },
	}
}

func servingWin() fakeWinHealth {
	return fakeWinHealth{
		pid: 4242, pidKnown: true, alive: true,
		status: controlReply{OK: true, PID: 4242, Layer: "default", Wanted: 30, Active: 30, Kwi3: "up"},
	}
}

func TestHealthWin32_EachCheckFailingInTurn(t *testing.T) {
	cases := []struct {
		name  string
		mod   func(*fakeWinHealth)
		code  int
		names string
	}{
		{"serving", func(*fakeWinHealth) {}, HealthOK, "serving"},
		{"no lock", func(f *fakeWinHealth) { f.pidKnown = false }, HealthNotServing, "lock:"},
		{"lock pid dead", func(f *fakeWinHealth) { f.alive = false }, HealthNotServing, "lock: pid 4242"},
		{"control silent", func(f *fakeWinHealth) { f.stErr = errors.New("connection refused") }, HealthNotServing, "control:"},
		{"control from another pid", func(f *fakeWinHealth) { f.status.PID = 99 }, HealthNotServing, "control:"},
		{"control refused", func(f *fakeWinHealth) { f.status = controlReply{OK: false, Error: "shutting down"} }, HealthNotServing, "control:"},
		{"chord not granted", func(f *fakeWinHealth) {
			f.status.Active = 29
			f.status.Missing = []string{"$mod+q: RegisterHotKey refused: ERROR_HOTKEY_ALREADY_REGISTERED (1409)"}
		}, HealthDegraded, "chords: 29 of 30"},
		{"kwi3rpc down", func(f *fakeWinHealth) { f.status.Kwi3 = "kwi3rpc: dial \\\\.\\pipe\\x: kwi3 unreachable" }, HealthNotServing, "kwi3rpc: the connection is down"},
		{"kwi3rpc none", func(f *fakeWinHealth) { f.status.Kwi3 = "" }, HealthNotServing, "kwi3rpc:"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := servingWin()
			c.mod(&f)
			code, msg := healthWin32("kwi3t-h", f.probes())
			if code != c.code || !strings.Contains(msg, c.names) {
				t.Fatalf("health = %d %q, want %d naming %q", code, msg, c.code, c.names)
			}
		})
	}
}

// The FIRST failing check is the one named: a dead pid is reported as the
// lock's, even though its control socket cannot answer either.
func TestHealthWin32_NamesTheFirstFailingCheck(t *testing.T) {
	f := servingWin()
	f.alive = false
	f.stErr = errors.New("refused")
	f.status.Kwi3 = "down"
	if _, msg := healthWin32("kwi3t-h", f.probes()); !strings.Contains(msg, "lock:") {
		t.Fatalf("health = %q, want the lock named first", msg)
	}
	f = servingWin()
	f.status.Active, f.status.Missing = 1, []string{"x"}
	f.status.Kwi3 = "down"
	if code, msg := healthWin32("kwi3t-h", f.probes()); code != HealthDegraded {
		t.Fatalf("health = %d %q, want chords (9) named before kwi3rpc", code, msg)
	}
}

// -- recover -------------------------------------------------------------------

type fakeProc struct {
	exitsOnStop bool
	stopped     bool
	terminated  bool
	waits       []time.Duration
	closed      bool
}

func (p *fakeProc) Wait(d time.Duration) bool {
	p.waits = append(p.waits, d)
	return (p.exitsOnStop && p.stopped) || p.terminated
}
func (p *fakeProc) Terminate() error { p.terminated = true; return nil }
func (p *fakeProc) Close()           { p.closed = true }

type fakeChild struct {
	pid  int
	code int
	done bool
}

func (c *fakeChild) PID() int            { return c.pid }
func (c *fakeChild) Exited() (int, bool) { return c.code, c.done }

type recoverRig struct {
	mu       sync.Mutex
	held     map[uint16]bool
	keyUps   []uint16
	lockPID  int
	named    bool
	held2    bool // lock held
	proc     *fakeProc
	opened   []int
	stops    int
	started  []argsRecord
	child    *fakeChild
	health   func() (int, string)
	clock    time.Time
	logger   *fakeLogger
	out      strings.Builder
	readArgs *argsRecord
}

func newRecoverRig() *recoverRig {
	r := &recoverRig{
		held:   map[uint16]bool{},
		proc:   &fakeProc{exitsOnStop: true},
		child:  &fakeChild{pid: 7777},
		clock:  time.Unix(1000, 0),
		logger: &fakeLogger{},
	}
	r.health = func() (int, string) { return HealthOK, "hotkeyd: d — serving" }
	return r
}

func (r *recoverRig) deps() recoverDeps {
	return recoverDeps{
		display: "kwi3t-r",
		keyDown: func(vk uint16) bool { return r.held[vk] },
		keyUp: func(vk uint16) error {
			r.keyUps = append(r.keyUps, vk)
			return nil
		},
		lockPID:  func(string) (int, bool) { return r.lockPID, r.named },
		lockHeld: func(string) bool { return r.held2 },
		openProc: func(pid int) (recoverProc, error) {
			r.opened = append(r.opened, pid)
			return r.proc, nil
		},
		stop: func(string) error {
			r.stops++
			r.proc.stopped = true
			return nil
		},
		readArgs: func(string) (argsRecord, bool) {
			if r.readArgs == nil {
				return argsRecord{}, false
			}
			return *r.readArgs, true
		},
		start: func(rec argsRecord) (recoverChild, error) {
			r.started = append(r.started, rec)
			// The new daemon takes the lock.
			r.lockPID, r.named, r.held2 = r.child.pid, true, true
			return r.child, nil
		},
		health: func(string) (int, string) { return r.health() },
		now:    func() time.Time { return r.clock },
		sleep:  func(d time.Duration) { r.clock = r.clock.Add(d) },
		log:    r.logger.log,
		out:    &r.out,
	}
}

func (r *recoverRig) runningDaemon(pid int) {
	r.lockPID, r.named, r.held2 = pid, true, true
}

func TestRecover_NoModifierHeld_NothingSent(t *testing.T) {
	r := newRecoverRig()
	r.runningDaemon(100)
	if code := recoverRun(r.deps()); code != 0 {
		t.Fatalf("recover = %d, want 0; out %q", code, r.out.String())
	}
	if len(r.keyUps) != 0 {
		t.Fatalf("key-ups sent with nothing held: %v", r.keyUps)
	}
	if !r.logger.contains("nothing sent") {
		t.Fatalf("log does not say nothing was sent: %v", r.logger.all())
	}
}

func TestRecover_ReleasesEveryHeldModifier_OneKeyUpEach_NothingElse(t *testing.T) {
	r := newRecoverRig()
	r.held[win32.VK_LSHIFT] = true
	r.held[win32.VK_RMENU] = true
	r.held[win32.VK_LWIN] = true
	r.held[win32.VK_SPACE] = true // not a modifier: never released
	r.runningDaemon(100)
	recoverRun(r.deps())
	want := []uint16{win32.VK_LSHIFT, win32.VK_RMENU, win32.VK_LWIN}
	if len(r.keyUps) != len(want) {
		t.Fatalf("key-ups %v, want exactly %v", r.keyUps, want)
	}
	for i := range want {
		if r.keyUps[i] != want[i] {
			t.Fatalf("key-ups %v, want exactly %v", r.keyUps, want)
		}
	}
}

func TestRecover_EveryModifierAskedAbout(t *testing.T) {
	r := newRecoverRig()
	for _, m := range recoverModifiers {
		r.held[m.vk] = true
	}
	r.runningDaemon(100)
	recoverRun(r.deps())
	if len(r.keyUps) != 8 {
		t.Fatalf("key-ups %v, want all eight sided modifiers", r.keyUps)
	}
}

func TestRecover_DryRunSendsNoKeyUp(t *testing.T) {
	r := newRecoverRig()
	r.held[win32.VK_LCONTROL] = true
	r.runningDaemon(100)
	d := r.deps()
	d.dryRun = true
	recoverRun(d)
	if len(r.keyUps) != 0 {
		t.Fatalf("dry run sent key-ups %v", r.keyUps)
	}
	if !r.logger.contains("DRY RUN") {
		t.Fatalf("dry run not said: %v", r.logger.all())
	}
}

func TestRecover_StopsOnControlStop_StartsWithOldArgs_ExitsZero(t *testing.T) {
	r := newRecoverRig()
	r.runningDaemon(100)
	r.readArgs = &argsRecord{PID: 100, Args: []string{"--input", "win32"}, Env: map[string]string{"KWI3SOCK": `\\.\pipe\x`}}
	code := recoverRun(r.deps())
	if code != 0 {
		t.Fatalf("recover = %d, want 0; out %q", code, r.out.String())
	}
	if len(r.opened) != 1 || r.opened[0] != 100 || r.stops != 1 {
		t.Fatalf("opened %v, stops %d; want pid 100 opened and one control stop", r.opened, r.stops)
	}
	if r.proc.terminated {
		t.Fatal("a daemon that stopped on the control socket was terminated too")
	}
	if !r.proc.closed {
		t.Fatal("the process handle was never closed")
	}
	if len(r.started) != 1 || strings.Join(r.started[0].Args, " ") != "--input win32" {
		t.Fatalf("started %+v, want one start with the old daemon's arguments", r.started)
	}
	if !strings.Contains(r.out.String(), "serving") {
		t.Fatalf("out %q, want the serving verdict", r.out.String())
	}
}

func TestRecover_StuckDaemonEndedByPid_Logged(t *testing.T) {
	r := newRecoverRig()
	r.runningDaemon(100)
	r.proc.exitsOnStop = false
	if code := recoverRun(r.deps()); code != 0 {
		t.Fatalf("recover = %d; out %q", code, r.out.String())
	}
	if !r.proc.terminated {
		t.Fatal("a daemon that ignored the stop was not ended")
	}
	if r.proc.waits[0] != 2*time.Second {
		t.Fatalf("waited %v after the stop, want 2s", r.proc.waits[0])
	}
	if !r.logger.contains("BY PID") || !r.logger.contains("pid 100") || !r.logger.contains("never by name") {
		t.Fatalf("ending by pid not logged: %v", r.logger.all())
	}
}

func TestRecover_NoDaemonRunning_StartsOneAndWaits(t *testing.T) {
	r := newRecoverRig()
	if code := recoverRun(r.deps()); code != 0 {
		t.Fatalf("recover = %d; out %q", code, r.out.String())
	}
	if len(r.opened) != 0 || r.stops != 0 {
		t.Fatalf("no daemon, yet opened %v / stops %d", r.opened, r.stops)
	}
	if len(r.started) != 1 {
		t.Fatalf("started %d daemons, want 1", len(r.started))
	}
}

// A pid in a lock nobody holds is a dead daemon's - the pid may be another
// program's by now, and it is never opened, stopped or ended.
func TestRecover_StaleLockPidNeverTouched(t *testing.T) {
	r := newRecoverRig()
	r.lockPID, r.named, r.held2 = 100, true, false
	recoverRun(r.deps())
	if len(r.opened) != 0 || r.stops != 0 || r.proc.terminated {
		t.Fatalf("stale pid touched: opened %v stops %d terminated %v", r.opened, r.stops, r.proc.terminated)
	}
	if len(r.started) != 1 {
		t.Fatal("no daemon started after a stale lock")
	}
}

func TestRecover_NotServingWithinTenSeconds_ExitsOneNamingTheCheck(t *testing.T) {
	r := newRecoverRig()
	r.runningDaemon(100)
	start := r.clock
	r.health = func() (int, string) {
		return HealthNotServing, "hotkeyd: d — NOT SERVING: kwi3rpc: the connection is down — dial: file not found"
	}
	if code := recoverRun(r.deps()); code != 1 {
		t.Fatalf("recover = %d, want 1", code)
	}
	if !strings.Contains(r.out.String(), "kwi3rpc") || !strings.Contains(r.out.String(), "10s") {
		t.Fatalf("out %q, want the last verdict naming kwi3rpc and the 10s bound", r.out.String())
	}
	if el := r.clock.Sub(start); el < 10*time.Second || el > 10*time.Second+recoverPoll {
		t.Fatalf("gave up after %v, want 10s", el)
	}
}

// Health that reads OK for the OLD pid (not yet the new one's lock) is not
// the new daemon serving.
func TestRecover_ServingMeansTheNewPid(t *testing.T) {
	r := newRecoverRig()
	r.runningDaemon(100)
	d := r.deps()
	start := d.start
	d.start = func(rec argsRecord) (recoverChild, error) {
		c, err := start(rec)
		r.lockPID = 100 // the old pid still in the file
		return c, err
	}
	if code := recoverRun(d); code != 1 {
		t.Fatalf("recover = %d with the lock still naming the old pid, want 1", code)
	}
}

func TestRecover_NewDaemonExitsEarly_ExitsOne(t *testing.T) {
	r := newRecoverRig()
	r.child.done, r.child.code = true, 3
	r.health = func() (int, string) { return HealthNotServing, "lock: pid 7777 is not running" }
	if code := recoverRun(r.deps()); code != 1 {
		t.Fatalf("recover = %d, want 1", code)
	}
	if !strings.Contains(r.out.String(), "exited with code 3") {
		t.Fatalf("out %q, want the early exit named", r.out.String())
	}
}

func TestArgsRecord_RoundTripAndChildEnv(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", dir)
	t.Setenv("LOCALAPPDATA", dir)
	if err := os.MkdirAll(proc.RuntimeDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	env := map[string]string{"KWI3SOCK": `\\.\pipe\kwi3-j-d`}
	if err := writeArgsRecord("kwi3t-a", []string{"--input", "win32"}, func(k string) string { return env[k] }); err != nil {
		t.Fatal(err)
	}
	rec, ok := readArgsRecord("kwi3t-a")
	if !ok || rec.PID != os.Getpid() || strings.Join(rec.Args, " ") != "--input win32" || rec.Env["KWI3SOCK"] != env["KWI3SOCK"] {
		t.Fatalf("record = %+v, %v", rec, ok)
	}
	if _, set := rec.Env[win32DryRunEnvName]; set {
		t.Fatal("an unset variable was recorded")
	}

	got := childEnv([]string{"PATH=x", "kwi3sock=old"}, rec)
	if envValue(got, "KWI3SOCK") != env["KWI3SOCK"] || len(got) != 2 {
		t.Fatalf("childEnv = %v, want KWI3SOCK replaced (case-insensitively), PATH kept", got)
	}

	// A dry-run recover never starts a daemon that registers chords, even
	// when the record says otherwise.
	rec.Env[win32DryRunEnvName] = "0"
	got = childEnv([]string{win32DryRunEnvName + "=1"}, rec)
	if envValue(got, win32DryRunEnvName) != "1" {
		t.Fatalf("childEnv = %v, want the dry run kept", got)
	}
	// And a dry-run daemon's restart stays dry.
	rec.Env[win32DryRunEnvName] = "1"
	got = childEnv([]string{"PATH=x"}, rec)
	if envValue(got, win32DryRunEnvName) != "1" {
		t.Fatalf("childEnv = %v, want the recorded dry run", got)
	}
}

// dialRaw sends line and returns the reply line exactly as written.
func dialRaw(path, line string) (string, error) {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return "", err
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(2 * time.Second))
	if _, err := conn.Write([]byte(line)); err != nil {
		return "", err
	}
	raw, err := bufio.NewReader(conn).ReadString('\n')
	if err != nil && raw == "" {
		return "", err
	}
	return strings.TrimSpace(raw), nil
}
