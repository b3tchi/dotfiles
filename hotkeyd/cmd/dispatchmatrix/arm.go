package main

// arm.go runs the whole plan against ONE engine and records what each press
// dispatched.
//
// # Three outcomes, never collapsed
//
// An empty capture is ambiguous, so this file never reports one as such. A
// trial ends as exactly one of:
//
//	dispatched     — the daemon produced i3 commands and/or Run actions
//	layer-change   — no i3 command and no Run, but the daemon moved layers
//	                 (an `enter:`/`exit` chord); it did something, so it must
//	                 not share a bucket with a chord that did nothing
//	silent         — the press demonstrably reached X, every capture channel
//	                 was demonstrably alive, and the daemon still did nothing
//	not-pressed    — xdotool refused the injection (its error is recorded)
//	not-prepared   — the required layer was never reached, or its grab set
//	                 never settled; the press was made against an unknown
//	                 state and the result is not evidence about anything
//	instrument-bad — the press reported success but the liveness audit says
//	                 the injection never reached X, or a capture channel died
//
// Only `dispatched` and `silent` are compared between arms. The other three
// are instrument verdicts and are reported as such.

import (
	"fmt"
	"reflect"
	"syscall"
	"time"
)

const (
	dispatchTimeout = 2500 * time.Millisecond
	dispatchQuiet   = 300 * time.Millisecond
	stateTimeout    = 4 * time.Second
	// settleDrain lets a transition's own resync and any trailing action
	// land before the next trial's capture window opens, so one trial's tail
	// is never read as the next trial's dispatch.
	settleDrain = 200 * time.Millisecond
)

// SilenceAudit is the same-run evidence that a null capture is the daemon's
// silence and not the harness's failure.
type SilenceAudit struct {
	InjectionReachedX bool `json:"injection_reached_x"`
	ProxyAlive        bool `json:"proxy_alive"`
	ActionLogReadable bool `json:"action_log_readable"`
	StateTailAlive    bool `json:"state_tail_alive"`
	DaemonAlive       bool `json:"daemon_alive"`
}

func (s SilenceAudit) allGood() bool {
	return s.InjectionReachedX && s.ProxyAlive && s.ActionLogReadable && s.StateTailAlive && s.DaemonAlive
}

func (s SilenceAudit) String() string {
	return fmt.Sprintf("inject=%v proxy=%v actionlog=%v statetail=%v daemon=%v",
		s.InjectionReachedX, s.ProxyAlive, s.ActionLogReadable, s.StateTailAlive, s.DaemonAlive)
}

type TrialResult struct {
	ID           string        `json:"id"`
	Group        string        `json:"group"`
	Kind         string        `json:"kind"`
	Chord        string        `json:"chord"`
	Press        string        `json:"press"`
	Expect       []string      `json:"expect"`
	StateAtPress string        `json:"state_at_press"`
	Prepared     bool          `json:"prepared"`
	PrepNote     string        `json:"prep_note"`
	Pressed      bool          `json:"pressed"`
	PressErr     string        `json:"press_err,omitempty"`
	I3           []string      `json:"i3"`
	Runs         []string      `json:"runs"`
	RunsReadOK   bool          `json:"runs_read_ok"`
	Trans        []string      `json:"transitions"`
	States       []string      `json:"states"`
	Outcome      string        `json:"outcome"`
	Audit        *SilenceAudit `json:"audit,omitempty"`
}

type ArmResult struct {
	Engine   string                  `json:"engine"`
	Mod      string                  `json:"mod"`
	Grabbed  int                     `json:"grabbed"`
	Order    []string                `json:"order"`
	Trials   map[string]*TrialResult `json:"trials"`
	InjErrs  []string                `json:"injector_errors"`
	Attempts int                     `json:"injector_attempts"`
	Notes    []string                `json:"notes"`
}

type Arm struct {
	engine  string
	display string
	dump    *Dump
	mod     string
	rig     *XRig
	inj     *Injector
	d       *Daemon
	probeX  string
	holding string
	notes   []string
}

// snapshot is everything observable, read at one instant.
type snapshot struct {
	i3     []string
	runs   []string
	runsOK bool
	trans  []string
	states []string
}

func (s snapshot) nonEmpty() bool {
	return len(s.i3) > 0 || len(s.runs) > 0 || len(s.trans) > 0 || len(s.states) > 0
}

func (a *Arm) snap(logMark int) snapshot {
	runs, ok := a.d.ActionsOK()
	states := []string{}
	for _, st := range a.d.State.States() {
		states = append(states, st.String())
	}
	return snapshot{
		i3:     a.d.Proxy.Commands(),
		runs:   runs,
		runsOK: ok,
		trans:  canonTransitions(transitionsIn(a.d.Log.Since(logMark))),
		states: states,
	}
}

func (a *Arm) daemonAlive() bool {
	if a.d.cmd == nil || a.d.cmd.Process == nil {
		return false
	}
	return a.d.cmd.Process.Signal(syscall.Signal(0)) == nil
}

// auditSilence fires the liveness probe and interrogates every capture
// channel, on the SAME run, at the moment the null was observed.
func (a *Arm) auditSilence() SilenceAudit {
	before := a.rig.ProbeCount()
	_ = a.inj.KeyChord(a.probeX)
	reached := waitFor(3*time.Second, func() bool {
		n := a.rig.ProbeCount()
		return n >= 0 && before >= 0 && n > before
	})
	_, readOK := a.d.ActionsOK()
	return SilenceAudit{
		InjectionReachedX: reached,
		ProxyAlive:        a.d.Proxy.Alive(a.display),
		ActionLogReadable: readOK,
		StateTailAlive:    a.d.State.Alive(),
		DaemonAlive:       a.daemonAlive(),
	}
}

func (a *Arm) currentLayer() string {
	if st, ok := a.d.State.Current(); ok {
		return st.Layer
	}
	return defaultLayerName
}

const defaultLayerName = "default"

// ensureDefault brings the daemon back to the default layer and waits for the
// default grab set to land.
func (a *Arm) ensureDefault() (bool, string) {
	for i := 0; i < 5; i++ {
		cur := a.currentLayer()
		if cur == defaultLayerName {
			if a.holding != "" {
				_ = a.inj.Up(a.holding)
				a.holding = ""
				time.Sleep(settleDrain)
			}
			return true, "default"
		}
		w := watchGrabs(a.display)
		mark := a.d.State.Mark()
		if a.holding != "" {
			_ = a.inj.Up(a.holding)
			a.holding = ""
		} else {
			l := a.dump.Layers[cur]
			key := "Escape"
			if len(l.ExitKeys) > 0 {
				key = l.ExitKeys[0]
			}
			a.inj.ReleaseModifiers()
			if press, err := XdoChord(key, a.mod); err == nil {
				_ = a.inj.KeyChord(press)
			}
		}
		if _, ok := a.d.State.AwaitFrom(mark, func(s State) bool { return s.Layer == defaultLayerName }, stateTimeout); ok {
			w.settled(grabSettleTimeout)
			time.Sleep(settleDrain)
			return true, "returned to default"
		}
	}
	return false, "could not return to the default layer from " + a.currentLayer()
}

// ensureLayer enters name and — this is the part that must not be skipped —
// waits for that layer's grab set to be PUBLISHED before returning. Both
// engines publish the new state before installing the grabs, and install them
// one chord at a time; python's 106-chord sync takes several hundred ms. A
// press fired on the state signal alone samples a half-installed grab set on
// the python arm only, which is exactly the shape of a false parity finding.
func (a *Arm) ensureLayer(name string) (bool, string) {
	if name == "" {
		return a.ensureDefault()
	}
	l := a.dump.Layers[name]
	if a.currentLayer() == name && (l.Hold == "" || a.holding != "") {
		return true, "already in " + name
	}
	if ok, why := a.ensureDefault(); !ok {
		return false, why
	}
	entry, ok := a.dump.EntryChord(name)
	if !ok {
		return false, "no entry chord for " + name
	}
	w := watchGrabs(a.display)
	mark := a.d.State.Mark()
	if l.Hold != "" {
		holdX, err := xdoModifier(l.Hold, a.mod)
		if err != nil {
			return false, err.Error()
		}
		if err := a.inj.Down(holdX); err != nil {
			return false, "hold keydown failed: " + err.Error()
		}
		a.holding = holdX
		press, err := XdoChordWithout(entry, a.mod, l.Hold)
		if err != nil {
			return false, err.Error()
		}
		if err := a.inj.KeyChord(press); err != nil {
			return false, "entry press failed: " + err.Error()
		}
	} else {
		press, err := XdoChord(entry, a.mod)
		if err != nil {
			return false, err.Error()
		}
		if err := a.inj.KeyChord(press); err != nil {
			return false, "entry press failed: " + err.Error()
		}
	}
	if _, ok := a.d.State.AwaitFrom(mark, func(s State) bool { return s.Layer == name }, stateTimeout); !ok {
		return false, "the daemon never published layer=" + name + " after " + entry
	}
	settled, why := w.settled(grabSettleTimeout)
	if !settled {
		return false, "the grab set for " + name + " never settled: " + why
	}
	time.Sleep(settleDrain)
	return true, "entered " + name + " (" + why + ")"
}

// RunPlan executes every trial against this arm's daemon.
func (a *Arm) RunPlan(plan []Trial, progress func(string)) *ArmResult {
	res := &ArmResult{
		Engine: a.engine, Mod: a.mod,
		Trials: map[string]*TrialResult{},
	}
	if n, _, ok := a.d.GrabSummary(); ok {
		res.Grabbed = n
	}
	for i, t := range plan {
		tr := &TrialResult{
			ID: t.ID, Group: t.Group, Kind: t.Kind, Chord: t.Chord,
			Press: t.Press, Expect: t.Expect,
		}
		prepared, note := a.ensureLayer(t.Layer)
		tr.Prepared, tr.PrepNote = prepared, note
		st, _ := a.d.State.Current()
		tr.StateAtPress = st.String()
		if tr.StateAtPress == "" {
			tr.StateAtPress = defaultLayerName
		}

		// Capture window opens only after the state is prepared and drained.
		a.d.Proxy.Reset()
		a.d.ResetActions()
		a.d.State.Reset()
		mark := a.d.Log.Mark()

		if !prepared {
			tr.Outcome = "not-prepared"
			res.Order = append(res.Order, t.ID)
			res.Trials[t.ID] = tr
			progress(fmt.Sprintf("[%s %3d/%3d] %-46s NOT-PREPARED %s", a.engine, i+1, len(plan), t.ID, note))
			continue
		}

		if err := a.inj.KeyChord(t.Press); err != nil {
			tr.Pressed, tr.PressErr, tr.Outcome = false, err.Error(), "not-pressed"
			res.Order = append(res.Order, t.ID)
			res.Trials[t.ID] = tr
			progress(fmt.Sprintf("[%s %3d/%3d] %-46s NOT-PRESSED %s", a.engine, i+1, len(plan), t.ID, err))
			continue
		}
		tr.Pressed = true

		s := a.captureAfterPress(mark)
		tr.I3, tr.Runs, tr.RunsReadOK, tr.Trans, tr.States = s.i3, s.runs, s.runsOK, s.trans, s.states

		switch {
		case len(s.i3) > 0 || len(s.runs) > 0:
			tr.Outcome = "dispatched"
		case len(s.trans) > 0 || len(s.states) > 0:
			// A pure layer move — `enter:`/`exit` with no i3 command and no
			// Run. It dispatched SOMETHING; calling it silent would put the
			// entry chords in the same bucket as a chord that did nothing at
			// all, which is the collapse this file exists to avoid.
			tr.Outcome = "layer-change"
		default:
			audit := a.auditSilence()
			tr.Audit = &audit
			if audit.allGood() {
				tr.Outcome = "silent"
			} else {
				tr.Outcome = "instrument-bad"
			}
			// The audit's own probe press may itself have moved the layer;
			// re-read so the next trial's ensure* sees the truth.
		}
		res.Order = append(res.Order, t.ID)
		res.Trials[t.ID] = tr
		progress(fmt.Sprintf("[%s %3d/%3d] %-46s %-14s i3=%v runs=%v",
			a.engine, i+1, len(plan), t.ID, tr.Outcome, s.i3, s.runs))
	}
	res.InjErrs = a.inj.Errors()
	res.Attempts = a.inj.Attempts()
	res.Notes = a.notes
	return res
}

// captureAfterPress waits for the dispatch to appear and then to go quiet.
func (a *Arm) captureAfterPress(mark int) snapshot {
	deadline := time.Now().Add(dispatchTimeout)
	last := a.snap(mark)
	stableSince := time.Now()
	sawSomething := last.nonEmpty()
	for {
		time.Sleep(15 * time.Millisecond)
		cur := a.snap(mark)
		if !sameSnapshot(cur, last) {
			last, stableSince = cur, time.Now()
			sawSomething = sawSomething || cur.nonEmpty()
		}
		if sawSomething && time.Since(stableSince) >= dispatchQuiet {
			return last
		}
		if time.Now().After(deadline) {
			return last
		}
	}
}

func sameSnapshot(a, b snapshot) bool {
	return reflect.DeepEqual(a.i3, b.i3) &&
		reflect.DeepEqual(a.runs, b.runs) &&
		reflect.DeepEqual(a.trans, b.trans) &&
		reflect.DeepEqual(a.states, b.states) &&
		a.runsOK == b.runsOK
}

// StartArm brings up one engine on the rig and returns it ready to run a plan.
func StartArm(engine string, argv []string, dump *Dump, rig *XRig, display, runtimeDir, mod string, inj *Injector) (*Arm, error) {
	proxy, err := StartI3Proxy(runtimeDir+"/i3-proxy-"+engine+".sock", rig.I3Sock)
	if err != nil {
		return nil, err
	}
	d, err := NewDaemon(engine, argv, display, runtimeDir, dump.RunTargets())
	if err != nil {
		proxy.Close()
		return nil, err
	}
	d.Proxy = proxy
	startWatch := watchGrabs(display)
	if err := d.Start(proxy.Path(), 30*time.Second); err != nil {
		proxy.Close()
		d.Cleanup()
		return nil, err
	}
	sw, err := WatchState(stateSocketPathFor(display))
	if err != nil {
		d.Cleanup()
		proxy.Close()
		return nil, err
	}
	d.State = sw
	a := &Arm{engine: engine, display: display, dump: dump, rig: rig, inj: inj, d: d}
	if ok, why := startWatch.settled(grabSettleTimeout); !ok {
		a.notes = append(a.notes, "startup grab set never settled: "+why)
	} else {
		a.notes = append(a.notes, "startup grab set settled: "+why)
	}
	_, gotMod, _ := d.GrabSummary()
	a.mod = gotMod
	if mod != "" && gotMod != mod {
		a.notes = append(a.notes, fmt.Sprintf(
			"$mod resolved to %s here but %s on the other arm — the plan is not comparable", gotMod, mod))
	}
	px, err := XdoChord(probeChord, a.mod)
	if err != nil {
		a.Close()
		return nil, err
	}
	a.probeX = px
	return a, nil
}

func (a *Arm) Close() {
	if a.holding != "" {
		_ = a.inj.Up(a.holding)
		a.holding = ""
	}
	a.inj.ReleaseModifiers()
	if a.d != nil {
		p := a.d.Proxy
		a.d.Cleanup()
		if p != nil {
			p.Close()
		}
	}
}
