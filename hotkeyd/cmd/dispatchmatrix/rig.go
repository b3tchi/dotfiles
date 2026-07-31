package main

// rig.go is the private-display test bed: an Xvfb, a real i3 in front of a
// recording IPC proxy, a sandbox HOME full of stubs, and one daemon process
// at a time.
//
// It is deliberately a near-copy of the machinery in cmd/livecheck rather
// than an import: that package is `main` and nothing can import it. The
// pieces reproduced here are the ones whose ABSENCE would make this harness
// unsound — the i3 proxy (the only way to see a dispatched i3 command from
// outside), the sandbox HOME (the only thing that stops a Run action spawning
// the operator's real scripts), and the grab-report settle (the only signal
// that a layer's grab set actually landed before the harness pressed anything).

import (
	"bufio"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"hotkeyd/internal/proc"
)

// ---------------------------------------------------------------------------
// environment pinning
// ---------------------------------------------------------------------------

// childEnv builds the environment for every process this harness spawns:
// DISPLAY pinned to the rig, I3SOCK scrubbed (i3 injects it into everything it
// execs, so an inherited one points at the operator's real session), and HOME
// redirected when a sandbox is given.
func childEnv(base []string, display, sandboxHome string, extra ...string) []string {
	out := make([]string, 0, len(base)+4+len(extra))
	for _, kv := range base {
		switch {
		case strings.HasPrefix(kv, "DISPLAY="), strings.HasPrefix(kv, "I3SOCK="):
			continue
		case sandboxHome != "" && strings.HasPrefix(kv, "HOME="):
			continue
		}
		out = append(out, kv)
	}
	out = append(out, "DISPLAY="+display)
	if sandboxHome != "" {
		out = append(out, "HOME="+sandboxHome)
	}
	return append(out, extra...)
}

// ---------------------------------------------------------------------------
// Xvfb + i3
// ---------------------------------------------------------------------------

// XRig is the private X server and the real i3 on top of it.
//
// The i3 config is minimal ON PURPOSE: it declares no bindings of its own
// except the injector probe below, so i3 never competes with hotkeyd for a
// table chord and a chord that goes undispatched cannot be explained by i3
// having eaten it.
type XRig struct {
	Display  string
	Dir      string
	I3Sock   string
	ProbeLog string

	xvfb, i3 *exec.Cmd
}

// probeChord is the chord wired to the injector-liveness probe in the rig's
// i3 config. It is NOT in the shipped table (checked at startup), so it also
// serves as the harness's negative control: hotkeyd must dispatch nothing for
// it while i3 demonstrably does something.
const probeChord = "$mod+F12"

func StartXRig(display, dir string) (*XRig, error) {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, err
	}
	r := &XRig{
		Display:  display,
		Dir:      dir,
		I3Sock:   filepath.Join(dir, "i3.sock"),
		ProbeLog: filepath.Join(dir, "probe.log"),
	}
	probeSh := filepath.Join(dir, "probe.sh")
	if err := os.WriteFile(probeSh,
		[]byte("#!/bin/sh\nprintf p >> "+r.ProbeLog+"\n"), 0o755); err != nil {
		return nil, err
	}
	if err := os.WriteFile(r.ProbeLog, nil, 0o644); err != nil {
		return nil, err
	}
	cfg := filepath.Join(dir, "i3.conf")
	if err := os.WriteFile(cfg, []byte(fmt.Sprintf(
		"font pango:monospace 8\nipc-socket %s\nbindsym Mod4+F12 exec --no-startup-id %s\n",
		r.I3Sock, probeSh)), 0o644); err != nil {
		return nil, err
	}

	r.xvfb = exec.Command("Xvfb", display, "-screen", "0", "800x600x24")
	r.xvfb.Env = childEnv(os.Environ(), display, "")
	r.xvfb.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := r.xvfb.Start(); err != nil {
		return nil, fmt.Errorf("dispatchmatrix: starting Xvfb on %s: %w", display, err)
	}
	sockPath := "/tmp/.X11-unix/X" + strings.TrimPrefix(display, ":")
	if !waitFor(10*time.Second, func() bool { _, err := os.Stat(sockPath); return err == nil }) {
		r.Stop()
		return nil, fmt.Errorf("dispatchmatrix: Xvfb never created %s", sockPath)
	}

	i3log, _ := os.Create(filepath.Join(dir, "i3.log"))
	r.i3 = exec.Command("i3", "-c", cfg)
	r.i3.Env = childEnv(os.Environ(), display, "")
	r.i3.Stdout, r.i3.Stderr = i3log, i3log
	r.i3.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := r.i3.Start(); err != nil {
		r.Stop()
		return nil, fmt.Errorf("dispatchmatrix: starting i3: %w", err)
	}
	if !waitFor(15*time.Second, func() bool { return r.i3Alive() }) {
		r.Stop()
		return nil, fmt.Errorf("dispatchmatrix: rig i3 never answered on %s", r.I3Sock)
	}
	return r, nil
}

func (r *XRig) i3Alive() bool {
	cmd := exec.Command("i3-msg", "-s", r.I3Sock, "-t", "get_version")
	cmd.Env = childEnv(os.Environ(), r.Display, "")
	return cmd.Run() == nil
}

// ProbeCount is how many times the injector-liveness binding has fired.
func (r *XRig) ProbeCount() int {
	b, err := os.ReadFile(r.ProbeLog)
	if err != nil {
		return -1
	}
	return len(b)
}

func (r *XRig) Stop() {
	killTree(r.i3)
	killTree(r.xvfb)
}

func killTree(c *exec.Cmd) {
	if c == nil || c.Process == nil {
		return
	}
	_ = syscall.Kill(-c.Process.Pid, syscall.SIGTERM)
	done := make(chan struct{})
	go func() { _, _ = c.Process.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		_ = syscall.Kill(-c.Process.Pid, syscall.SIGKILL)
	}
}

func waitFor(d time.Duration, pred func() bool) bool {
	deadline := time.Now().Add(d)
	for {
		if pred() {
			return true
		}
		if time.Now().After(deadline) {
			return false
		}
		time.Sleep(50 * time.Millisecond)
	}
}

// ---------------------------------------------------------------------------
// i3 IPC recording proxy
// ---------------------------------------------------------------------------

const i3Magic = "i3-ipc"
const i3TypeRunCommand uint32 = 0

func scanFrames(r io.Reader, onFrame func(mtype uint32, payload []byte)) error {
	header := make([]byte, len(i3Magic)+8)
	for {
		if _, err := io.ReadFull(r, header); err != nil {
			return err
		}
		if string(header[:len(i3Magic)]) != i3Magic {
			return fmt.Errorf("i3 proxy: bad frame magic %q", header[:len(i3Magic)])
		}
		length := binary.LittleEndian.Uint32(header[len(i3Magic):])
		mtype := binary.LittleEndian.Uint32(header[len(i3Magic)+4:])
		payload := make([]byte, length)
		if _, err := io.ReadFull(r, payload); err != nil {
			return err
		}
		onFrame(mtype, payload)
	}
}

// I3Proxy is a recording man-in-the-middle on the i3 IPC socket. The daemon
// connects here via $HOTKEYD_I3SOCK, every frame is relayed verbatim to the
// REAL i3, and every RUN_COMMAND payload is recorded on the way past.
type I3Proxy struct {
	path     string
	upstream string
	ln       net.Listener

	mu   sync.Mutex
	cmds []string
}

func StartI3Proxy(path, upstream string) (*I3Proxy, error) {
	_ = os.Remove(path)
	ln, err := net.Listen("unix", path)
	if err != nil {
		return nil, fmt.Errorf("i3 proxy: listen %s: %w", path, err)
	}
	p := &I3Proxy{path: path, upstream: upstream, ln: ln}
	go func() {
		for {
			c, err := p.ln.Accept()
			if err != nil {
				return
			}
			go p.serve(c)
		}
	}()
	return p, nil
}

func (p *I3Proxy) serve(client net.Conn) {
	defer client.Close()
	server, err := net.Dial("unix", p.upstream)
	if err != nil {
		return
	}
	defer server.Close()
	go func() { _, _ = io.Copy(client, server) }()

	pr, pw := io.Pipe()
	go func() {
		_ = scanFrames(pr, func(mtype uint32, payload []byte) {
			if mtype != i3TypeRunCommand {
				return
			}
			p.mu.Lock()
			p.cmds = append(p.cmds, string(payload))
			p.mu.Unlock()
		})
		_, _ = io.Copy(io.Discard, pr)
	}()
	_, _ = io.Copy(server, io.TeeReader(client, pw))
	pw.Close()
}

func (p *I3Proxy) Commands() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return append([]string{}, p.cmds...)
}

func (p *I3Proxy) Reset() {
	p.mu.Lock()
	p.cmds = nil
	p.mu.Unlock()
}

func (p *I3Proxy) Path() string { return p.path }

func (p *I3Proxy) Close() {
	p.ln.Close()
	_ = os.Remove(p.path)
}

// Alive proves the RECORDING path still works, independently of the daemon:
// this harness opens its own connection to the proxy, sends a `nop`, and
// checks the proxy saw it. Used to tell "the daemon dispatched nothing" from
// "the observer stopped observing" — the two look identical otherwise.
func (p *I3Proxy) Alive(display string) bool {
	c, err := net.Dial("unix", p.path)
	if err != nil {
		return false
	}
	defer c.Close()
	const payload = "nop dispatchmatrix-proxy-alive"
	buf := make([]byte, 0, len(i3Magic)+8+len(payload))
	buf = append(buf, i3Magic...)
	var head [8]byte
	binary.LittleEndian.PutUint32(head[0:], uint32(len(payload)))
	binary.LittleEndian.PutUint32(head[4:], i3TypeRunCommand)
	buf = append(buf, head[:]...)
	buf = append(buf, payload...)
	if _, err := c.Write(buf); err != nil {
		return false
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		for _, cmd := range p.Commands() {
			if cmd == payload {
				return true
			}
		}
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

// ---------------------------------------------------------------------------
// daemon stderr + transition log
// ---------------------------------------------------------------------------

type logSink struct {
	mu      sync.Mutex
	partial string
	lines   []string
}

func (s *logSink) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.partial += string(p)
	for {
		i := strings.IndexByte(s.partial, '\n')
		if i < 0 {
			break
		}
		s.lines = append(s.lines, strings.TrimRight(s.partial[:i], "\r"))
		s.partial = s.partial[i+1:]
	}
	return len(p), nil
}

func (s *logSink) Lines() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return append([]string{}, s.lines...)
}

func (s *logSink) Mark() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.lines)
}

func (s *logSink) Since(mark int) []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	if mark > len(s.lines) {
		return nil
	}
	return append([]string{}, s.lines[mark:]...)
}

func (s *logSink) Await(pred func(string) bool, timeout time.Duration) (string, bool) {
	deadline := time.Now().Add(timeout)
	for {
		for _, l := range s.Lines() {
			if pred(l) {
				return l, true
			}
		}
		if time.Now().After(deadline) {
			return "", false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// ---------------------------------------------------------------------------
// state socket
// ---------------------------------------------------------------------------

type State struct{ Layer, Mod string }

func (s State) String() string {
	if s.Mod == "" {
		return s.Layer
	}
	return s.Layer + "/" + s.Mod
}

type wireState struct {
	Layer *string `json:"layer"`
	Mod   *string `json:"mod"`
}

type StateWatcher struct {
	conn net.Conn

	mu      sync.Mutex
	states  []State // since the last Reset — one trial's worth
	last    State   // the most recent state EVER published
	hasLast bool
	err     error
	closed  bool
}

func WatchState(path string) (*StateWatcher, error) {
	conn, err := net.Dial("unix", path)
	if err != nil {
		return nil, fmt.Errorf("dispatchmatrix: state socket %s: %w", path, err)
	}
	w := &StateWatcher{conn: conn}
	go func() {
		sc := bufio.NewScanner(conn)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if line == "" {
				continue
			}
			var ws wireState
			w.mu.Lock()
			if err := json.Unmarshal([]byte(line), &ws); err != nil || ws.Layer == nil {
				w.err = fmt.Errorf("unparsable state line %q", line)
			} else {
				st := State{Layer: *ws.Layer}
				if ws.Mod != nil {
					st.Mod = *ws.Mod
				}
				w.states = append(w.states, st)
				w.last, w.hasLast = st, true
			}
			w.mu.Unlock()
		}
		w.mu.Lock()
		w.closed = true
		w.mu.Unlock()
	}()
	return w, nil
}

func (w *StateWatcher) States() []State {
	w.mu.Lock()
	defer w.mu.Unlock()
	return append([]State{}, w.states...)
}

// Alive reports whether the socket reader is still running — the state
// channel's own liveness, so an empty state list can be told apart from a
// dead tail.
func (w *StateWatcher) Alive() bool {
	w.mu.Lock()
	defer w.mu.Unlock()
	return !w.closed
}

// Current is the daemon's LAST published state, which deliberately survives
// Reset.
//
// Reset clears the per-trial window; it must not clear the harness's idea of
// which layer the daemon is in, because most in-layer presses publish nothing
// (they neither enter nor leave a layer). Reading "where are we" off the
// per-trial window would make every such press look like a return to the
// default layer, and the next trial would then press the entry chord a second
// time from inside the layer — which publishes nothing, times out, and grades
// as not-prepared. Caught by reasoning through the switcher/nav sequences
// before the full run, not by a failing trial.
func (w *StateWatcher) Current() (State, bool) {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.last, w.hasLast
}

// Mark is the current length of the per-trial state window. Paired with
// AwaitFrom it makes a wait unambiguous: a state published BEFORE the input
// can never satisfy a wait for the state that input is supposed to produce.
func (w *StateWatcher) Mark() int {
	w.mu.Lock()
	defer w.mu.Unlock()
	return len(w.states)
}

func (w *StateWatcher) AwaitFrom(mark int, pred func(State) bool, timeout time.Duration) (State, bool) {
	deadline := time.Now().Add(timeout)
	for {
		all := w.States()
		if mark <= len(all) {
			for _, st := range all[mark:] {
				if pred(st) {
					return st, true
				}
			}
		}
		if time.Now().After(deadline) {
			return State{}, false
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func (w *StateWatcher) Reset() {
	w.mu.Lock()
	w.states = nil
	w.mu.Unlock()
}

func (w *StateWatcher) Close() {
	if w.conn != nil {
		w.conn.Close()
	}
}

// ---------------------------------------------------------------------------
// grab-report settle  (the piece that must not be skipped)
// ---------------------------------------------------------------------------
//
// Both daemons publish the layer's new STATE before the layer's GRABS are
// installed, and install the grab set one chord at a time. A press fired the
// instant the state socket says "nav" therefore lands on a half-installed
// grab set — python's 106-chord sync takes several hundred ms, the Go
// daemon's tens, so only the python arm ever loses that race and the result
// reads as a parity divergence that is not one. sp021's first FALSE parity
// finding was exactly this.
//
// Waiting for the report to STOP CHANGING is unsound: while a sync is in
// flight the report on disk is the stale PREVIOUS one, and a stale report is
// perfectly stable. What is sound is that a PUBLICATION of the report proves
// a sync completed, because the write is the last thing a sync does. So take
// a baseline before the input and wait for the report to be published again.

const (
	grabSettleTimeout = 6 * time.Second
	grabQuiet         = 250 * time.Millisecond
	grabPoll          = 20 * time.Millisecond
)

type reportStamp struct {
	present bool
	ino     uint64
	mtime   int64
	size    int64
	body    string
}

func stampGrabReport(display string) reportStamp {
	path := proc.GrabReportPath(display)
	fi, err := os.Stat(path)
	if err != nil {
		return reportStamp{}
	}
	st := reportStamp{present: true, mtime: fi.ModTime().UnixNano(), size: fi.Size()}
	if sys, ok := fi.Sys().(*syscall.Stat_t); ok {
		st.ino = sys.Ino
	}
	if b, err := os.ReadFile(path); err == nil {
		st.body = string(b)
	}
	return st
}

type grabWatch struct {
	display string
	base    reportStamp
}

// watchGrabs snapshots the report as it stands NOW. Call it before the
// injection whose resync it will wait for, never after.
func watchGrabs(display string) *grabWatch {
	return &grabWatch{display: display, base: stampGrabReport(display)}
}

func (w *grabWatch) settled(timeout time.Duration) (bool, string) {
	deadline := time.Now().Add(timeout)
	advanced := false
	last := w.base
	var quietSince time.Time
	for {
		cur := stampGrabReport(w.display)
		switch {
		case !advanced:
			if cur.present && cur != w.base {
				advanced, last, quietSince = true, cur, time.Now()
			}
		case cur != last:
			last, quietSince = cur, time.Now()
		case time.Since(quietSince) >= grabQuiet:
			r, ok := proc.CurrentGrabReport(w.display)
			if !ok {
				return false, "the settled grab report is not the live daemon's (pid does not match the display lock)"
			}
			return true, fmt.Sprintf("wanted=%d active=%d missing=%v", r.Wanted, r.Active, r.Missing)
		}
		if time.Now().After(deadline) {
			if !advanced {
				return false, "no NEW grab report was published within " + timeout.String() +
					" — the sidecar still holds the pre-input report (" + w.base.body + ")"
			}
			return false, "the grab report was still changing after " + timeout.String()
		}
		time.Sleep(grabPoll)
	}
}

// ---------------------------------------------------------------------------
// injector
// ---------------------------------------------------------------------------

// Injector drives real key events into the rig through XTEST, via xdotool.
//
// Every invocation is env-pinned to the rig, so an injector can never land on
// the caller's session even if $DISPLAY says otherwise. Its failures are
// surfaced as their own signal: during an earlier task in this epic an invalid
// long option made EVERY injection fail silently and thirteen claims went red
// about the daemon while the fault was in the instrument.
type Injector struct {
	display  string
	env      []string
	errs     []string
	attempts int
}

func NewInjector(display string) *Injector {
	return &Injector{display: display, env: childEnv(os.Environ(), display, "")}
}

func (in *Injector) Errors() []string    { return append([]string{}, in.errs...) }
func (in *Injector) Attempts() int       { return in.attempts }
func (in *Injector) Available() bool     { _, err := exec.LookPath("xdotool"); return err == nil }
func (in *Injector) Key(c string) error  { return in.run("key", c) }
func (in *Injector) Down(c string) error { return in.run("keydown", c) }
func (in *Injector) Up(c string) error   { return in.run("keyup", c) }

// KeyChord injects a chord by holding its modifiers DOWN across a separate
// press of the key, instead of handing xdotool one "mods+key" string.
//
// # Why, measured rather than assumed
//
// The first full run of this harness reported `$mod+Print` and
// `$mod+Shift+Print` as SILENT on BOTH engines, while bare `Print`
// dispatched. Three independent measurements took that apart:
//
//  1. A bare i3 rig with `bindcode Mod4+107` fired on `xdotool key
//     super+Print`, so the chord did reach X.
//  2. A rival XI2 passive grab was REFUSED on (keycode 107, mask 0x40) and
//     (107, 0x41) while either daemon ran, so both daemons genuinely HELD
//     those grabs — the grab report's `missing=[]` was telling the truth.
//  3. On a clean rig with no i3 Print binding, `xdotool key super+Print`
//     dispatched nothing, while `xdotool keydown super` + `xdotool key
//     Print` + `xdotool keyup super` dispatched `i3-scrot -w` — the correct
//     action for `$mod+Print` — against that same daemon.
//
// So the silence was the INSTRUMENT's. xdotool resolves a whole "mods+key"
// sequence in one go and picks a different encoding for the Print keysym in
// that form (this keymap carries Print on two keycodes, 107 and 218, and
// twice within 107's own row). Decomposing is also closer to what a human
// keyboard does. Had this not been chased down, two of the seventy shipped
// chords would have been reported as "neither engine dispatches this" — a
// claim about the daemons manufactured entirely by the harness.
func (in *Injector) KeyChord(press string) error {
	parts := strings.Split(press, "+")
	if len(parts) == 1 {
		return in.Key(press)
	}
	mods, key := parts[:len(parts)-1], parts[len(parts)-1]
	for i, m := range mods {
		if err := in.Down(m); err != nil {
			for j := i - 1; j >= 0; j-- {
				_ = in.Up(mods[j])
			}
			return err
		}
	}
	err := in.Key(key)
	for i := len(mods) - 1; i >= 0; i-- {
		if e := in.Up(mods[i]); e != nil && err == nil {
			err = e
		}
	}
	return err
}

func (in *Injector) run(args ...string) error {
	in.attempts++
	cmd := exec.Command("xdotool", args...)
	cmd.Env = in.env
	out, err := cmd.CombinedOutput()
	if err != nil {
		e := fmt.Errorf("xdotool %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(string(out)))
		in.errs = append(in.errs, e.Error())
		return e
	}
	return nil
}

// ReleaseModifiers puts the keyboard back in a known state. Called between
// trials so a stuck modifier from one press can never be mistaken for the
// next chord's behaviour.
func (in *Injector) ReleaseModifiers() {
	for _, m := range []string{"super", "alt", "ctrl", "shift"} {
		_ = in.Up(m)
	}
}

// ---------------------------------------------------------------------------
// daemon under test
// ---------------------------------------------------------------------------

// stubScript is what every Run target in the table is replaced by inside the
// sandbox HOME: it records how it was invoked and exits 0. $0 is recorded as
// well as the arguments so `~/.local/bin/i3exit` and a bare `i3exit` off PATH
// are distinguishable.
const stubScript = `#!/bin/sh
printf '%s|%s\n' "$0" "$*" >> "$DISPATCHMATRIX_ACTIONS"
exit 0
`

type Daemon struct {
	Name      string
	Argv      []string
	Display   string
	Runtime   string
	Home      string
	ActionLog string

	cmd   *exec.Cmd
	Log   *logSink
	State *StateWatcher
	Proxy *I3Proxy
}

func NewDaemon(name string, argv []string, display, runtimeDir string, targets []string) (*Daemon, error) {
	home, err := os.MkdirTemp("", "dm-home-")
	if err != nil {
		return nil, err
	}
	actions := filepath.Join(home, "actions.log")
	for _, rel := range targets {
		if strings.HasPrefix(rel, "ABS:") {
			return nil, fmt.Errorf(
				"dispatchmatrix: the table names %s, which the sandbox HOME cannot intercept; "+
					"refusing to run rather than spawn it for real", strings.TrimPrefix(rel, "ABS:"))
		}
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
	return &Daemon{
		Name: name, Argv: argv, Display: display, Runtime: runtimeDir,
		Home: home, ActionLog: actions,
	}, nil
}

func (d *Daemon) Start(i3Sock string, timeout time.Duration) error {
	d.Log = &logSink{}
	cmd := exec.Command(d.Argv[0], append(append([]string{}, d.Argv[1:]...), "--display", d.Display)...)
	cmd.Env = childEnv(os.Environ(), d.Display, d.Home,
		"XDG_RUNTIME_DIR="+d.Runtime,
		"DISPATCHMATRIX_ACTIONS="+d.ActionLog,
		"HOTKEYD_I3SOCK="+i3Sock,
		// The sandbox bin first, so a bare-command action resolves to the
		// stub and never to a real one on the operator's PATH.
		"PATH="+filepath.Join(d.Home, ".local", "bin")+":"+os.Getenv("PATH"),
	)
	cmd.Stdout, cmd.Stderr = d.Log, d.Log
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("dispatchmatrix: starting %v: %w", d.Argv, err)
	}
	d.cmd = cmd
	if _, ok := d.Log.Await(func(l string) bool { _, _, ok := parseGrabSummary(l); return ok }, timeout); !ok {
		d.Stop()
		return fmt.Errorf("dispatchmatrix: %s never reported its grab set within %s; log:\n%s",
			d.Name, timeout, strings.Join(d.Log.Lines(), "\n"))
	}
	return nil
}

func (d *Daemon) GrabSummary() (int, string, bool) {
	for _, l := range d.Log.Lines() {
		if n, mod, ok := parseGrabSummary(l); ok {
			return n, mod, true
		}
	}
	return 0, "", false
}

// ActionsOK returns the recorded Run dispatches AND whether the log could be
// read. The two must stay separate: "the daemon dispatched nothing" and "this
// observer could not look" are the same empty slice otherwise.
func (d *Daemon) ActionsOK() ([]string, bool) {
	b, err := os.ReadFile(d.ActionLog)
	if err != nil {
		return nil, false
	}
	var out []string
	for _, l := range strings.Split(string(b), "\n") {
		if s := strings.TrimSpace(l); s != "" {
			// The sandbox HOME is a fresh temp dir per arm, so a `~/...`
			// target's $0 differs between arms for a reason that has nothing
			// to do with dispatch. Fold it back to `~`.
			out = append(out, strings.ReplaceAll(s, d.Home, "~"))
		}
	}
	return out, true
}

func (d *Daemon) ResetActions() { _ = os.WriteFile(d.ActionLog, nil, 0o644) }

func (d *Daemon) Stop() int {
	if d.cmd == nil || d.cmd.Process == nil {
		return -1
	}
	_ = syscall.Kill(-d.cmd.Process.Pid, syscall.SIGTERM)
	done := make(chan error, 1)
	go func() { done <- d.cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		_ = syscall.Kill(-d.cmd.Process.Pid, syscall.SIGKILL)
		<-done
	}
	code := d.cmd.ProcessState.ExitCode()
	d.cmd = nil
	return code
}

func (d *Daemon) Cleanup() {
	if d.cmd != nil {
		d.Stop()
	}
	if d.State != nil {
		d.State.Close()
	}
	_ = os.RemoveAll(d.Home)
}
