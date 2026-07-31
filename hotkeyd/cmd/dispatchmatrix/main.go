// Command dispatchmatrix presses EVERY chord in the shipped hotkeyd bind
// table against the Go daemon and against the Python daemon, on one private
// X display, and diffs what each engine dispatched — chord for chord.
//
// # What this proves that the golden-dump test does not
//
// cmd/hotkeyd/config_test.go's TestGoldenDumpParity already proves the two
// TABLES are identical: it shells out to python3 against the live binds.py on
// every run and compares chord sets and action inventories for all 70 binds
// and all 4 layers. What it cannot prove is that a chord, PRESSED, dispatches
// the same thing on both engines — that is a property of the running daemons,
// not of the table. cmd/livecheck grades that property by sampling. This tool
// exercises the whole table.
//
// # Safety
//
// This tool starts daemons that grab keyboard chords. On the machine this was
// written on, a live session sits on :10.0, and an earlier task in this epic
// inherited it and hijacked the operator's keyboard for five minutes. So:
// $DISPLAY is never read, --display is mandatory, anything below :60 is
// refused without an explicit named opt-out, every child process is env-pinned
// to the rig with I3SOCK scrubbed and HOME redirected into a sandbox, and the
// rig's Xvfb + i3 are started and torn down by this process.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"sort"
	"strconv"
	"strings"
	"time"

	"hotkeyd/internal/layer"
)

func stateSocketPathFor(display string) string { return layer.SocketPath(display) }

// unsafeDisplayEnv is the single, named opt-out of the refusal below. Named
// rather than a bare flag so it shows up in a process listing and so grepping
// the repo finds every caller.
const unsafeDisplayEnv = "HOTKEYD_DISPATCHMATRIX_UNSAFE_DISPLAY"

// lowestPrivateDisplay: :0/:1 are native sessions and :10 is adr0004's xrdp
// session; sibling harnesses in this epic have used :40-:52, so this tool
// starts at :60 to stay clear of them too.
const lowestPrivateDisplay = 60

// resolveTargetDisplay returns the display this tool may operate on, or the
// refusal. It does NOT consult $DISPLAY — an inherited display is the only way
// this lands on a live session.
func resolveTargetDisplay(flagDisplay string, env func(string) string) (string, error) {
	d := strings.TrimSpace(flagDisplay)
	if d == "" {
		return "", fmt.Errorf("dispatchmatrix: no display given — pass --display :<n> explicitly; " +
			"this tool starts daemons that grab the whole table and will not inherit $DISPLAY")
	}
	if !strings.HasPrefix(d, ":") {
		return "", fmt.Errorf("dispatchmatrix: --display %q must be a local display like :60", d)
	}
	numPart := strings.SplitN(strings.TrimPrefix(d, ":"), ".", 2)[0]
	n, err := strconv.Atoi(numPart)
	if err != nil {
		return "", fmt.Errorf("dispatchmatrix: --display %q does not parse", d)
	}
	if n < lowestPrivateDisplay && env(unsafeDisplayEnv) == "" {
		return "", fmt.Errorf(
			"dispatchmatrix: refusing --display %q — anything below :%d may be a live session "+
				"(:0/:1 native, :10 xrdp, :40-:52 used by sibling harnesses in this epic); "+
				"start a private Xvfb on :%d or higher, or set %s=1 if you really mean it",
			d, lowestPrivateDisplay, lowestPrivateDisplay, unsafeDisplayEnv)
	}
	return d, nil
}

func main() { os.Exit(run(os.Args[1:])) }

func run(argv []string) int {
	fs := flag.NewFlagSet("dispatchmatrix", flag.ContinueOnError)
	display := fs.String("display", "", "the PRIVATE X display to build the rig on (required, >= :60)")
	goBin := fs.String("go-hotkeyd", "", "the Go hotkeyd binary (required)")
	pyBin := fs.String("py-hotkeyd", "", "hotkeyd.py (required)")
	python := fs.String("python", "python3", "python interpreter")
	hotkeydDir := fs.String("hotkeyd-dir", "", "the hotkeyd/ directory, for `import binds` (required)")
	jsonOut := fs.String("json", "", "write the full per-trial record here")
	only := fs.String("only", "", "comma-separated trial-id substrings; run only matching trials")
	quiet := fs.Bool("quiet", false, "suppress per-trial progress lines")
	if err := fs.Parse(argv); err != nil {
		return 2
	}

	// --- safety instrument, graded before it is trusted -------------------
	if code := selfTestDisplayGuard(); code != 0 {
		return code
	}

	target, err := resolveTargetDisplay(*display, os.Getenv)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	if *goBin == "" || *pyBin == "" || *hotkeydDir == "" {
		fmt.Fprintln(os.Stderr, "dispatchmatrix: --go-hotkeyd, --py-hotkeyd and --hotkeyd-dir are all required")
		return 2
	}
	for _, b := range []string{"Xvfb", "i3", "i3-msg", "xdotool"} {
		if _, err := exec.LookPath(b); err != nil {
			fmt.Fprintf(os.Stderr, "dispatchmatrix: %s is not on PATH\n", b)
			return 2
		}
	}

	runtimeDir, err := os.MkdirTemp("", "dm-rt-")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	defer os.RemoveAll(runtimeDir)
	// Every path the daemons and this process resolve — lock, state socket,
	// grab report — is read from $XDG_RUNTIME_DIR at call time. Pinning it
	// here keeps all of them inside the rig.
	os.Setenv("XDG_RUNTIME_DIR", runtimeDir)

	dump, err := LoadDump(*hotkeydDir, *python)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	fmt.Printf("table: %d top-level binds, %d layers (%s)\n",
		len(dump.Binds), len(dump.Layers), strings.Join(dump.LayerNames(), ", "))

	rig, err := StartXRig(target, filepath.Join(runtimeDir, "rig"))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	defer rig.Stop()
	fmt.Printf("rig: Xvfb + i3 on %s (i3 socket %s)\n", target, rig.I3Sock)

	inj := NewInjector(target)

	// --- instrument grading: does the injector actually inject? -----------
	if !selfTestInjector(rig, inj) {
		fmt.Fprintln(os.Stderr,
			"dispatchmatrix: the injector self-test FAILED — xdotool reported success but no key "+
				"reached the rig's i3. Every result downstream of this would be noise; refusing to run.")
		return 3
	}
	fmt.Println("instrument: injector self-test PASSED (an injected chord reached the rig's i3)")

	progress := func(s string) {
		if !*quiet {
			fmt.Println(s)
		}
	}

	// --- arm 1: Go --------------------------------------------------------
	armGo, err := StartArm("go", []string{*goBin}, dump, rig, target, runtimeDir, "", inj)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dispatchmatrix: go arm:", err)
		return 3
	}
	plan, err := BuildPlan(dump, armGo.mod)
	if err != nil {
		armGo.Close()
		fmt.Fprintln(os.Stderr, err)
		return 2
	}
	plan = filterPlan(plan, *only)
	fmt.Printf("plan: %d trials, $mod=%s\n", len(plan), armGo.mod)
	resGo := armGo.RunPlan(plan, progress)
	armGo.Close()
	time.Sleep(500 * time.Millisecond)

	// --- arm 2: Python ----------------------------------------------------
	armPy, err := StartArm("python", []string{*python, *pyBin}, dump, rig, target, runtimeDir, armGo.mod, inj)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dispatchmatrix: python arm:", err)
		return 3
	}
	resPy := armPy.RunPlan(plan, progress)
	armPy.Close()

	divs := Diff(plan, resGo, resPy)

	// --- confirmation pass: every divergence measured a second time -------
	//
	// sp021 has already produced one FALSE parity finding from sampling a
	// race, so a difference seen once is a hypothesis, not a result. The
	// confirmation runs the divergent trials only, in FRESH daemons, with the
	// arms in the opposite order — so an order effect or a one-off race shows
	// up as a divergence that does not reproduce.
	var conf *Confirmation
	if len(divs) > 0 {
		ids := map[string]bool{}
		for _, d := range divs {
			ids[d.ID] = true
		}
		sub := make([]Trial, 0, len(ids))
		for _, t := range plan {
			if ids[t.ID] {
				sub = append(sub, t)
			}
		}
		fmt.Printf("\nconfirmation pass: re-measuring %d divergent trials in fresh daemons, python first\n", len(sub))
		conf = confirm(sub, dump, rig, target, runtimeDir, armGo.mod, inj, []string{*python, *pyBin}, []string{*goBin}, progress)
	}

	report(plan, resGo, resPy, divs, conf)

	if *jsonOut != "" {
		blob := map[string]any{
			"display": target, "mod": armGo.mod,
			"go": resGo, "python": resPy,
			"divergences": divs, "confirmation": conf,
		}
		b, _ := json.MarshalIndent(blob, "", "  ")
		if err := os.WriteFile(*jsonOut, b, 0o644); err != nil {
			fmt.Fprintln(os.Stderr, "dispatchmatrix: writing json:", err)
		} else {
			fmt.Printf("\nfull per-trial record: %s\n", *jsonOut)
		}
	}

	rig.Stop()
	verifyNoStrays(target)

	if len(divs) > 0 {
		return 1
	}
	return 0
}

func filterPlan(plan []Trial, only string) []Trial {
	only = strings.TrimSpace(only)
	if only == "" {
		return plan
	}
	pats := strings.Split(only, ",")
	var out []Trial
	for _, t := range plan {
		for _, p := range pats {
			if strings.Contains(t.ID, strings.TrimSpace(p)) {
				out = append(out, t)
				break
			}
		}
	}
	return out
}

// selfTestDisplayGuard grades the SAFETY instrument before anything is
// started: a guard that silently permits is worse than no guard, and the only
// way to know it refuses is to watch it refuse.
func selfTestDisplayGuard() int {
	noEnv := func(string) string { return "" }
	for _, bad := range []string{"", ":0", ":1", ":10", ":10.0", ":52", "remote:0"} {
		if got, err := resolveTargetDisplay(bad, noEnv); err == nil {
			fmt.Fprintf(os.Stderr,
				"dispatchmatrix: SAFETY SELF-TEST FAILED — the display guard accepted %q (as %q). "+
					"Refusing to run: an instrument that cannot refuse cannot protect the live session.\n",
				bad, got)
			return 4
		}
	}
	if got, err := resolveTargetDisplay(":60", noEnv); err != nil || got != ":60" {
		fmt.Fprintf(os.Stderr,
			"dispatchmatrix: SAFETY SELF-TEST FAILED — the display guard rejected the legal rig :60 (%v)\n", err)
		return 4
	}
	fmt.Println("safety: display guard self-test PASSED (refuses \"\", :0, :1, :10, :10.0, :52; admits :60)")
	return 0
}

// selfTestInjector proves the injector actually injects on the rig BEFORE any
// verdict depends on it. An earlier task in this epic passed an invalid option
// to xdotool, every injection failed silently, and thirteen claims went red
// about the daemon while the fault was in the harness.
func selfTestInjector(rig *XRig, inj *Injector) bool {
	if !inj.Available() {
		return false
	}
	before := rig.ProbeCount()
	if before < 0 {
		return false
	}
	if err := inj.KeyChord("super+F12"); err != nil {
		fmt.Fprintln(os.Stderr, "dispatchmatrix: injector self-test:", err)
		return false
	}
	return waitFor(5*time.Second, func() bool { return rig.ProbeCount() > before })
}

// verifyNoStrays reports any process still holding the rig display.
func verifyNoStrays(display string) {
	out, _ := exec.Command("pgrep", "-af", "Xvfb "+display).Output()
	lines := strings.TrimSpace(string(out))
	if lines != "" {
		fmt.Fprintf(os.Stderr, "dispatchmatrix: STRAY Xvfb on %s:\n%s\n", display, lines)
		return
	}
	fmt.Printf("teardown: no Xvfb remains on %s\n", display)
}

// ---------------------------------------------------------------------------
// diff
// ---------------------------------------------------------------------------

type Divergence struct {
	ID     string   `json:"id"`
	Group  string   `json:"group"`
	Chord  string   `json:"chord"`
	Field  string   `json:"field"`
	Go     []string `json:"go"`
	Python []string `json:"python"`
	GoOut  string   `json:"go_outcome"`
	PyOut  string   `json:"python_outcome"`
}

// Diff compares the two arms trial for trial.
//
// The comparison is split by CHANNEL so a cosmetic difference in one cannot
// hide or manufacture a dispatch finding in another:
//
//	outcome      — dispatched / silent / instrument verdicts
//	dispatch     — the i3 commands and Run actions, which IS "what fired"
//	transitions  — the layer engine's own log, folded engine-neutrally
//	states       — the public state-socket sequence
func Diff(plan []Trial, a, b *ArmResult) []Divergence {
	var out []Divergence
	for _, t := range plan {
		ta, oka := a.Trials[t.ID]
		tb, okb := b.Trials[t.ID]
		if !oka || !okb {
			out = append(out, Divergence{ID: t.ID, Group: t.Group, Chord: t.Chord,
				Field: "missing", Go: []string{fmt.Sprint(oka)}, Python: []string{fmt.Sprint(okb)}})
			continue
		}
		add := func(field string, x, y []string) {
			if !reflect.DeepEqual(nz(x), nz(y)) {
				out = append(out, Divergence{
					ID: t.ID, Group: t.Group, Chord: t.Chord, Field: field,
					Go: nz(x), Python: nz(y), GoOut: ta.Outcome, PyOut: tb.Outcome,
				})
			}
		}
		if ta.Outcome != tb.Outcome {
			out = append(out, Divergence{ID: t.ID, Group: t.Group, Chord: t.Chord,
				Field: "outcome", Go: []string{ta.Outcome}, Python: []string{tb.Outcome},
				GoOut: ta.Outcome, PyOut: tb.Outcome})
		}
		add("i3", ta.I3, tb.I3)
		// Run actions are compared as a MULTISET, not a sequence.
		//
		// MEASURED, not assumed: `layer:switcher|space` came back as
		// [search, cancel] on the Go arm and [cancel, search] on the python
		// arm, and the confirmation pass — same trial, fresh daemons —
		// returned [search, cancel] on BOTH. The order is not the engine's:
		// each Run action is a detached `/bin/sh -c` (proc.Run / Popen with
		// start_new_session), and two shells spawned microseconds apart append
		// to the stub log in whichever order the kernel schedules them. An
		// ordered comparison here measures the scheduler. The i3 channel above
		// stays ORDERED because those commands go down one socket in sequence,
		// where order really is the engine's.
		add("runs", sortedCopy(ta.Runs), sortedCopy(tb.Runs))
		add("transitions", ta.Trans, tb.Trans)
		add("states", ta.States, tb.States)
	}
	return out
}

// sortedCopy is the multiset form of a capture channel.
func sortedCopy(s []string) []string {
	out := append([]string{}, s...)
	sort.Strings(out)
	return out
}

func nz(s []string) []string {
	if s == nil {
		return []string{}
	}
	return s
}

// ---------------------------------------------------------------------------
// confirmation pass
// ---------------------------------------------------------------------------

// Confirmation is the second measurement of every divergence the main pass
// found: the same trials, fresh daemons, arms in the opposite order. Whether
// each one REPRODUCED is derived in report() by intersecting Divergences with
// the main pass's, so there is one source of truth for it rather than two.
type Confirmation struct {
	Trials      []string     `json:"trials"`
	Divergences []Divergence `json:"divergences"`
}

func confirm(sub []Trial, dump *Dump, rig *XRig, display, runtimeDir, mod string,
	inj *Injector, firstArgv, secondArgv []string, progress func(string)) *Confirmation {

	c := &Confirmation{}
	for _, t := range sub {
		c.Trials = append(c.Trials, t.ID)
	}
	a1, err := StartArm("python2", firstArgv, dump, rig, display, runtimeDir, mod, inj)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dispatchmatrix: confirmation python arm:", err)
		return c
	}
	r1 := a1.RunPlan(sub, progress)
	a1.Close()
	time.Sleep(500 * time.Millisecond)

	a2, err := StartArm("go2", secondArgv, dump, rig, display, runtimeDir, mod, inj)
	if err != nil {
		fmt.Fprintln(os.Stderr, "dispatchmatrix: confirmation go arm:", err)
		return c
	}
	r2 := a2.RunPlan(sub, progress)
	a2.Close()

	c.Divergences = Diff(sub, r2, r1) // go, python — same argument order as the main pass
	return c
}

// ---------------------------------------------------------------------------
// report
// ---------------------------------------------------------------------------

func report(plan []Trial, a, b *ArmResult, divs []Divergence, conf *Confirmation) {
	fmt.Println("\n=== ARM SUMMARY ===")
	for _, r := range []*ArmResult{a, b} {
		counts := map[string]int{}
		for _, tr := range r.Trials {
			counts[tr.Outcome]++
		}
		keys := make([]string, 0, len(counts))
		for k := range counts {
			keys = append(keys, k)
		}
		sort.Strings(keys)
		parts := make([]string, 0, len(keys))
		for _, k := range keys {
			parts = append(parts, fmt.Sprintf("%s=%d", k, counts[k]))
		}
		fmt.Printf("%-8s $mod=%s grabbed=%d trials=%d  %s\n",
			r.Engine, r.Mod, r.Grabbed, len(r.Trials), strings.Join(parts, " "))
		// The count is CUMULATIVE across arms — one injector serves the rig,
		// so the second arm's figure includes the first's. What matters here
		// is the refusal count, which must be zero: a refused injection is a
		// press that never happened, and a press that never happened must
		// never be graded as a silent daemon.
		fmt.Printf("         injector: %d invocations (cumulative), %d refused\n", r.Attempts, len(r.InjErrs))
		for _, e := range r.InjErrs {
			fmt.Printf("           REFUSED: %s\n", e)
		}
		for _, n := range r.Notes {
			fmt.Printf("         note: %s\n", n)
		}
	}

	fmt.Println("\n=== PER-CHORD COMPARISON ===")
	fmt.Printf("%-46s %-12s %-12s %s\n", "TRIAL", "GO", "PYTHON", "VERDICT")
	divByID := map[string][]string{}
	for _, d := range divs {
		divByID[d.ID] = append(divByID[d.ID], d.Field)
	}
	same, diff := 0, 0
	for _, t := range plan {
		ta, tb := a.Trials[t.ID], b.Trials[t.ID]
		ga, gb := "?", "?"
		if ta != nil {
			ga = ta.Outcome
		}
		if tb != nil {
			gb = tb.Outcome
		}
		verdict := "SAME"
		if f, ok := divByID[t.ID]; ok {
			verdict = "DIFFERENT (" + strings.Join(f, ",") + ")"
			diff++
		} else {
			same++
		}
		fmt.Printf("%-46s %-12s %-12s %s\n", t.ID, ga, gb, verdict)
	}
	fmt.Printf("\n%d/%d trials identical on both engines, %d divergent\n", same, len(plan), diff)

	// Order-only differences in the Run channel are surfaced rather than
	// silently swallowed by the multiset comparison: they are not dispatch
	// divergences (see Diff), but hiding them entirely would be the same
	// mistake in the other direction.
	var orderOnly []string
	for _, t := range plan {
		ta, tb := a.Trials[t.ID], b.Trials[t.ID]
		if ta == nil || tb == nil {
			continue
		}
		if !reflect.DeepEqual(nz(ta.Runs), nz(tb.Runs)) &&
			reflect.DeepEqual(nz(sortedCopy(ta.Runs)), nz(sortedCopy(tb.Runs))) {
			orderOnly = append(orderOnly,
				fmt.Sprintf("  %-42s go=%v python=%v", t.ID, ta.Runs, tb.Runs))
		}
	}
	if len(orderOnly) > 0 {
		fmt.Println("\n=== RUN-ACTION ORDER-ONLY DIFFERENCES (same actions, different append order) ===")
		fmt.Println("These are NOT dispatch divergences: each Run action is a detached /bin/sh, and")
		fmt.Println("two shells spawned microseconds apart append to the stub log in scheduler order.")
		for _, l := range orderOnly {
			fmt.Println(l)
		}
	}

	if len(divs) == 0 {
		fmt.Println("\n=== DIVERGENCES ===\nnone")
		return
	}
	fmt.Println("\n=== DIVERGENCES (in full) ===")
	for _, d := range divs {
		fmt.Printf("\n%s  [%s]  field=%s\n", d.ID, d.Chord, d.Field)
		fmt.Printf("  go     (%s): %v\n", d.GoOut, d.Go)
		fmt.Printf("  python (%s): %v\n", d.PyOut, d.Python)
	}
	if conf != nil {
		fmt.Println("\n=== CONFIRMATION PASS ===")
		confKeys := map[string]bool{}
		for _, d := range conf.Divergences {
			confKeys[d.ID+"|"+d.Field] = true
		}
		for _, d := range divs {
			k := d.ID + "|" + d.Field
			if confKeys[k] {
				fmt.Printf("  REPRODUCED  %s field=%s\n", d.ID, d.Field)
			} else {
				fmt.Printf("  VANISHED    %s field=%s  <- seen once, not on re-measurement: treat as a race in the harness or the rig, not a parity finding\n", d.ID, d.Field)
			}
			delete(confKeys, k)
		}
		for k := range confKeys {
			fmt.Printf("  NEW         %s  <- appeared only on the confirmation pass\n", k)
		}
	}
}
