// Package main — dispatchmatrix's findings and the run of record.
//
// FROZEN INSTRUMENT — THIS TOOL CAN NO LONGER RUN (dotfiles-ylmp.16).
//
// dispatchmatrix is a TWO-ARM differ: it presses every chord in the shipped
// table against the Go daemon and against the Python daemon on one private X
// display, and diffs what each dispatched. hotkeyd.py and binds.py were
// deleted when the estate cut over to Go, so one arm no longer exists and
// LoadDump's `import binds` cannot resolve. Running it now stops at the
// required-flags check with a message naming this.
//
// It is retained rather than deleted because what it produced is EVIDENCE, not
// code: the run of record below (and testdata/run-of-record.txt) is the
// measurement that let the cutover proceed, and deleting the instrument would
// leave the finding with nothing to describe how it was taken. To run it again
// you would need binds.py and hotkeyd.py back out of git history
// (`git log -- hotkeyd/binds.py`), which is the correct amount of friction.
//
// Its removal is proposed separately — see the bd issue filed from
// dotfiles-ylmp.16 — because deleting a documented instrument is a decision
// about the record, not a loose end of the cutover.
//
// main.go documents what the tool IS. This file documents what it FOUND, so
// the evidence ships with the instrument rather than in a chat log. Written
// for bd dotfiles-ws5b, ahead of dotfiles-ylmp.15's parity gate.
//
// # The gap this closes
//
// cmd/hotkeyd/config_test.go's TestGoldenDumpParity proves the two TABLES
// agree: it shells out to python3 against the live binds.py every run and
// compares chord sets and action inventories for all 70 binds and all 4
// layers, and it has been shown to fail on drift. cmd/livecheck proves that
// grabs install, that dispatch happens, that layers transition and that
// devices are attributed — but it samples; it does not press all 70. Nobody
// had pressed every chord in the shipped table against both engines and
// diffed the results. That is what this tool does.
//
// # The run of record
//
// testdata/run-of-record.txt is the full per-trial table. Summary:
//
//	display     a private Xvfb + real i3, started and torn down by the harness
//	$mod        Mod4 on both arms (read off each daemon's own startup line)
//	grabs       wanted=70 active=70 missing=[] on both arms, settled before
//	            any press
//	plan        127 trials — the 70 top-level binds, all 4 layers' binds,
//	            both nav sublayers, every layer's exit keys, a sublayer
//	            precedence trial and a negative control
//	go arm      dispatched=113  layer-change=13  silent=1  not-pressed=0
//	            not-prepared=0  instrument-bad=0
//	python arm  dispatched=113  layer-change=13  silent=1  not-pressed=0
//	            not-prepared=0  instrument-bad=0
//	VERDICT     127/127 trials identical on both engines, 0 divergences
//
// The single `silent` on each arm is the negative control ($mod+F12, not in
// the table): hotkeyd dispatched nothing while the rig's i3 demonstrably
// fired on the same press, which is what makes the other 126 non-silent
// results mean something.
//
// # The three known traps, as measured
//
// dotfiles-9y8n — sublayer precedence. internal/layer's activeMod breaks a
// tie between sublayers ALPHABETICALLY by label, where hotkeyd.py breaks it
// by declaration order; that was accepted on the grounds that it matches
// every shipped table, by inspection. Measured here: `precedence:nav`
// holds Ctrl AND Mod1 together and presses `h`, the key both nav sublayers
// bind. BOTH engines dispatched `move left` — the `move` sublayer, which is
// both alphabetically first and declared first. The inspection argument now
// has a measurement behind it. Note what this does NOT show: nav is the only
// multi-sublayer layer in the shipped table, so the two orderings have never
// been made to disagree. A future layer whose declaration order and
// alphabetical order differ would diverge, and nothing here would have
// caught it in advance — the trial is generated from the table, so it will
// exist and fail the day such a layer is added.
//
// dotfiles-y2ju — "Alt+Tab no longer opens the switcher on native :0".
// The trial `default|$mod+Tab` taps the chord the way a user does (press and
// release everything). Both engines produced BYTE-IDENTICAL behaviour,
// including the transition log:
//
//	transition layer=default->switcher ... trigger=press:Tab keycode=23
//	           mask=0x40 mods=Mod4 sourceid=5
//	           device=Virtual core XTEST keyboard held=none i3_mode=default
//	transition layer=switcher->default ... trigger=none held=none
//	           i3_mode=default note=hold-released:Mod4
//
// and the same three Run actions: qs-overlay.sh switcher (the bind),
// switcher-confirm (the layer's on_hold_release), switcher-cancel (its
// on_exit). So the daemon DOES open the switcher on $mod+Tab, on both
// engines. What a fast tap also does is release $mod immediately, which
// fires hold-release and exits the layer — the overlay is asked to open and
// then confirmed-and-closed within milliseconds. Held-$mod trials
// (`layer:switcher|*`) show the layer behaving correctly for as long as the
// modifier is down. Whatever y2ju is, it is not an engine-level dispatch
// difference between the two implementations, and it is not the Go rewrite:
// the python engine does exactly the same thing.
//
// dotfiles-n0r4 — the engines quote `device=` differently (python's !r gives
// single quotes, Go's %q double) and pad `mask=` differently. transition.go
// tokenises quote-aware and folds both spellings plus none/None before
// anything is compared; harness_test.go's TestTransitionParsingIsEngineNeutral
// pins it, and TestTransitionRealDifferenceStillShows pins that the folding
// is not so aggressive that a real difference hides in it. With that in
// place the transition channel compared EQUAL on all 127 trials. Had the
// comparison been raw-line, every transition in the run would have been
// reported as a divergence.
//
// # Two instrument faults found and fixed before the verdict was believed
//
// Both are recorded because "grade your own instrument" is the rule this
// epic keeps re-learning, and because both would have produced confident
// false claims ABOUT THE DAEMONS.
//
//  1. xdotool's `key mods+key` form does not deliver `$mod+Print` on this
//     keymap. The first full run reported $mod+Print and $mod+Shift+Print
//     silent on BOTH engines. Three measurements took it apart — an i3
//     bindcode rig proved the chord reached X, a rival XI2 grab proved both
//     daemons genuinely HELD (keycode 107, mask 0x40), and a clean rig showed
//     the decomposed press dispatching `i3-scrot -w` correctly against the
//     same daemon. The fix is Injector.KeyChord (rig.go), which holds the
//     modifiers down across a separate press of the key. After it, both
//     chords dispatch on both engines and the negative control stays silent.
//
//  2. Run-action ORDER is the kernel's, not the engine's. `layer:switcher|
//     space` came back [search, cancel] on Go and [cancel, search] on python,
//     and the confirmation pass returned [search, cancel] on both. Each Run
//     action is a detached /bin/sh (proc.Run / Popen(start_new_session)), and
//     two shells spawned microseconds apart append to the stub log in
//     scheduler order. Diff therefore compares the Run channel as a MULTISET
//     and the i3 channel — one socket, written in sequence — as a SEQUENCE.
//     Order-only differences are still printed, under a heading that says
//     what they are.
//
// # An observation that is NOT a parity finding
//
// The switcher's `space` and `Return` binds each end in ExitLayer, and the
// layer's on_exit is `qs-overlay.sh switcher-cancel`. So confirming a
// selection ALSO fires switcher-cancel, and so does the search gesture. Both
// engines do this identically, so it is shipped behaviour rather than
// rewrite drift — but if the overlay treats cancel as "discard", confirm may
// be being undone. Worth a look from the quickshell side; out of scope here.
//
// # What this run does not establish
//
//   - It runs on Xvfb with $mod=Mod4. The xrdp :10 session resolves $mod to
//     Mod1 and reports a different keysyms_per_keycode; every keycode here is
//     resolved at run time, but no arm was run under Mod1. The Mod1 path is
//     covered by cmd/livecheck's runModOnePhase, not by this tool.
//   - Injected events come from the XTEST slave, so every trial's
//     `sourceid`/`device` is XTEST's. Physical-device attribution is
//     livecheck's claim, not this one.
//   - It compares the two engines to EACH OTHER. A behaviour both engines get
//     wrong in the same way reads as parity here, correctly — the golden-dump
//     test and the story's acceptance criteria are what say whether the
//     shared behaviour is right.
package main
