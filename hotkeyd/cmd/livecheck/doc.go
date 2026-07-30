// Command livecheck is the Go re-expression of hotkeyd/live_check.py: the
// assertions that fakes cannot make. A REAL XI2 passive grab against a real
// X server, with NumLock and CapsLock actually toggled, driving the REAL Go
// daemon binary on a real i3 and reading the effect back off the state
// socket, the transition log and i3 itself.
//
// It prints one `PASS` / `FAIL` / `SKIP` line per claim and exits non-zero
// if anything FAILED. test-hotkeyd.sh's stage 6 routes to it through
// $HOTKEYD_LIVECHECK (default: python3 live_check.py, so nothing changes
// until a caller opts in).
//
// # Safety: never the ambient display
//
// --display is REQUIRED and $DISPLAY is never consulted for a default, and
// :0-:19 are refused outright. This tool grabs chords and starts a daemon
// that grabs the whole shipped table; twice during sp021 a run inherited a
// developer's live $DISPLAY and hijacked the session. See display.go.
//
// # What is different from live_check.py, and why
//
// live_check.py constructs the daemon IN PROCESS: it imports hotkeyd, builds
// an H.Daemon, feeds it events by hand and reads its private chord set and
// engine state. The Go daemon cannot be driven that way — cmd/hotkeyd is
// package main, so nothing can import it, and its bind table is COMPILED IN
// (the dwm model; there is no --binds flag). So this tool observes the
// shipped binary from outside, through the four channels it actually
// exposes:
//
//	grab present       a rival XI2 grab on the same chord. Two X clients
//	                   cannot both hold one passive grab, so a REFUSAL is
//	                   the server confirming the daemon OBTAINED the chord.
//	                   Stronger than reading a chord set, which only ever
//	                   proved what was requested.
//	dispatch observed  a recording i3 IPC proxy in front of the REAL i3
//	                   (via $HOTKEYD_I3SOCK), plus stub scripts in a
//	                   sandbox $HOME for the table's `run` actions.
//	layer transitions  the state socket, one JSON line per change.
//	device attribution the transition log's sourceid= / device= fields.
//
// Two consequences follow, and they are the whole content of the
// python-only column below: claims about a bind table this binary cannot
// load (device-scoped binds, IGNORE_DEVICES) and claims that require
// HIDING an event from the daemon's own X connection (the phantom-hold
// reconcile) have no out-of-process expression at all.
//
// # Precondition gating ([[im009]])
//
// Every claim whose subject might not materialise is gated on a
// precondition READ OFF THE SAME RUN, and a missing precondition yields
// SKIP — never PASS. See Reporter.Judged in report.go for the failure this
// prevents. Injected input is itself such a precondition: without xdotool
// on PATH every injection-dependent claim SKIPs.
//
// # THE INVENTORY
//
// live_check.py is 910 lines and contains 87 assertion call sites (85
// `check(` + 1 `judged(` + a two-armed try/except pair at py:900/902 that
// emits exactly one line). At runtime it emits 91 PASS/FAIL lines, because
// py:148 runs twice and py:700/702 run three times each while only one arm
// of py:900/902 executes. All four figures were re-derived from the source
// and from a live run of the python suite for this task; do not trust them
// second-hand.
//
// Every one of the 87 sites is accounted for below — 77 re-expressed in Go,
// 10 python-only with a stated reason. inventory_test.go re-parses
// live_check.py and fails if any site is missing, duplicated, unexplained,
// or invented.
//
//	py:130	GO	the display speaks XI2 -- mechanism.go, XIQueryVersion >= 2
//	py:136	GO	a real XIPassiveGrabDevice registers $mod+F10 with zero refused modifier variants
//	py:140	GO	chord fires with no lock keys (3/3)
//	py:148	GO	chord fires with NumLock ON, and with CapsLock ON (poc013's finding, re-measured)
//	py:164	GO	a key we did NOT grab is not delivered -- the grab is per chord, never exclusive
//	py:168	GO	while the chord we DID grab still arrives (the anti-vacuity twin)
//	py:191	GO	a chord another XI2 client already grabbed is REFUSED and reported
//	py:194	GO	a fully refused chord is not recorded as ours; the daemon's own grab report is checked too
//	py:196	GO	the other chord is still grabbed after a refusal
//	py:200	GO	and that other chord still FIRES after the refusal
//	py:214	GO	the core grabber holds its grab -- the REAL i3, via its `bindsym Mod4+F8` marker binding
//	py:215	GO	an XI2 grab over a live CORE grab is NOT refused (separate conflict domains; corrects sp020)
//	py:226	GO	and the LATER (XI2) grabber wins delivery outright -- i3's mark is absent afterwards
//	py:238	GO	i3 dispatch over the persistent socket returned success -- internal/i3's real Client
//	py:239	GO	i3 accepted the command -- the mark is present in GET_MARKS
//	py:243	GO	one connection survived 120+ dispatches -- the SAME fd before and after, not merely non-nil
//	py:254	GO	chords still resolve after a keymap reset
//	py:257	GO	chord still fires after a keymap reset
//	py:296	GO	bare h is NOT grabbed in the default layer -- a rival grab on it is granted
//	py:299	GO	$mod+o enters nav on a real server -- observed on the state socket
//	py:301	GO	entering nav GRABBED its bare keys -- a rival grab on bare h is now refused
//	py:302	GO	entering nav GRABBED the sublayer modifier key (Control_L)
//	py:306	GO	bare h in nav DISPATCHES `focus left` to the real i3
//	py:314	GO	a really-held Ctrl is observed as the move sublayer
//	py:317	GO	Ctrl+h MOVES instead of focusing
//	py:321	GO	q leaves the layer while Ctrl is still held
//	py:329	GO	leaving the layer RELEASED its bare keys again
//	py:342	GO	entering nav OBTAINED a Shift-held grab for every exit key (q, Escape, Return)
//	py:352	GO	held Shift does NOT become a sublayer
//	py:355	GO	Shift+q leaves the layer
//	py:394	GO	XI2 marks auto-repeat on the PRESS and sends no synthetic release -- measured on this run
//	py:402	GO	a held key fires ONCE despite the real auto-repeat stream -- GATED on py:394's measurement
//	py:457	GO	still in nav for the repeat-filter fairness checks
//	py:474	GO	a 10 ms double-tap really does put release+press of the SAME key on two milliseconds
//	py:478	GO	and the server does NOT flag either tap as a repeat -- gated on py:474
//	py:481	GO	a 10 ms double-tap dispatches TWICE -- gated on py:474
//	py:498	GO	a rolling h,j pair really does land release+press of DIFFERENT keys on ONE millisecond
//	py:502	GO	a same-millisecond release+press of DIFFERENT keys keeps BOTH -- gated on py:498
//	py:519	GO	the display's XI2 inventory names an XTEST keyboard
//	py:527	GO	and a second, distinct keyboard device to scope a negative case to
//	py:537	GO	every grabbed event resolves its source to the XTEST keyboard (injected input IS XTEST)
//	py:540	GO	and sourceid is the SLAVE, not the master in the event header
//	py:577	PYTHON-ONLY	a bind scoped to device=<XTEST> FIRES for that source. The Go daemon's table is COMPILED IN and has no --binds flag (check.go's "dwm model"), and the shipped table contains no device-scoped bind, so no such bind can be installed in the running binary from outside. Covered instead by internal/layer's engine_test.go over Bind.Device, plus py:628's live proof that the daemon's own dispatch path carries the real sourceid/device end to end.
//	py:582	PYTHON-ONLY	the same bind scoped to another device is INERT. Same reason as py:577 -- no runtime table injection exists in the Go binary.
//	py:589	PYTHON-ONLY	IGNORE_DEVICES drops every event from that source. bind.IgnoreDevices ships EMPTY and is a compiled-in package variable; nothing outside the process can set it. Covered by internal/layer's unit tests.
//	py:593	PYTHON-ONLY	an IGNORE_DEVICES naming something else changes nothing. Same reason as py:589.
//	py:611	GO	back in the default layer for the transition-log checks
//	py:618	GO	entering nav on a real server emits exactly ONE transition line
//	py:623	GO	the transition names the keycode the server sent
//	py:626	GO	and the modifier mask the event arrived with
//	py:628	GO	and the SOURCE DEVICE -- the XTEST injector, the field that separates injected from typed
//	py:635	GO	and leaving nav names the key that did it
//	py:654	GO	a really-held Ctrl is observed as the move sublayer (the same live claim as py:314)
//	py:657	PYTHON-ONLY	reconcile_mods() returns False while the server confirms the hold. The return value of one internal call has no out-of-process surface. Its OBSERVABLE consequence -- a genuinely-held modifier is not retracted by the idle poll -- is graded live at py:790.
//	py:665	PYTHON-ONLY	a LOST release leaves the phantom sublayer standing. The lost release is manufactured by draining the daemon's OWN event queue before it can see it; an out-of-process observer cannot hide an event from a connection it does not own. The daemon's active grab always delivers a Ctrl release.
//	py:669	PYTHON-ONLY	the idle reconcile drops the phantom against the server's own mask. Same reason as py:665 -- the phantom cannot be produced from outside. The reconcile mechanism itself IS graded live, on the one lost release a real server does produce: the switcher's $mod release (py:807/809/811), which no grab can deliver.
//	py:672	PYTHON-ONLY	while the LAYER -- which X has no opinion about -- is untouched by the retraction. It is a claim ABOUT the phantom retraction of py:669, so it cannot outlive the phantom that py:665 shows is unproducible from outside the daemon's own connection.
//	py:696	GO	the shipped switcher layer's whole grab set is obtainable -- zero entries in the daemon's grab report `missing`
//	py:700	GO	$mod+Escape and q were actually GRABBED, not merely requested (rival-grab probe)
//	py:702	GO	Super_R and $mod+Shift+q are deliberately absent from a hold layer's grab set
//	py:710	GO	ISO_Left_Tab resolves, and to the SAME keycode as Tab
//	py:714	GO	$mod+Tab is named Tab -- cycle forwards
//	py:716	GO	$mod+Shift+Tab is named ISO_Left_Tab -- cycle BACKWARDS
//	py:770	GO	Super_L is ungrabbed in the default layer, which is why commit cannot be gated on belief
//	py:775	GO	$mod+Tab opens the switcher and DISPATCHES the layer's own action
//	py:776	GO	and takes the layer -- observed on the state socket
//	py:778	GO	entering the layer did NOT grab the held modifier's keysym
//	py:781	GO	and the layer's grabs cost zero refusals
//	py:784	GO	a second Tab, still with $mod down, cycles forwards
//	py:786	GO	and Shift+Tab cycles BACKWARDS on a real server
//	py:790	GO	while $mod is genuinely down the hold-release action is NOT dispatched
//	py:793	GO	the layer is still up
//	py:801	PYTHON-ONLY	the $mod release delivers NO event to the daemon at all. This reads the daemon's own event queue after the release; from outside there is no way to observe an event's ABSENCE from another process's connection. What the absence causes IS graded: py:807 only passes because the poll, not an event, ended the layer.
//	py:803	PYTHON-ONLY	so on events alone the layer would be stuck up. Same reason as py:801 -- it is a statement about what the daemon did NOT receive.
//	py:807	GO	asking the server ends it -- releasing $mod brings the layer down
//	py:809	GO	the layer is down -- the state socket's final line is the default layer
//	py:811	GO	and the commit was DISPATCHED, not merely implied by the exit
//	py:814	GO	the layer's bare keys went back to applications with it
//	py:841	GO	i3wm.mod: Mod1 merged onto the live display is readable back off the root window
//	py:863	GO	the daemon detected $mod=Mod1 for itself
//	py:868	GO	Super+o does NOT enter nav where $mod is Mod1
//	py:875	GO	Alt+o DOES enter nav where $mod is Mod1 -- grab set and engine agree
//	py:879	GO	and the layer's bare keys were grabbed on the way in
//	py:884	GO	a nav bind dispatches on the Mod1 display
//	py:888	GO	q leaves nav on the Mod1 display
//	py:900	GO	a second instance on the same display is refused (exit 3)
//	py:902	GO	the same claim's other arm -- one line is emitted either way
//
// # What the Go suite checks that live_check.py does not
//
// The out-of-process shape buys four claims the in-process one cannot make,
// and they are graded here rather than left implicit:
//
//	the daemon's own grab report publishes an EMPTY `missing` list on a
//	real server (py:696's external twin, read from the sidecar);
//	`one connection survived 120+ dispatches` is checked as the same file
//	descriptor before and after, not merely a non-nil socket;
//	every "grabbed" claim is the SERVER refusing a rival grab, not the
//	daemon's own record of what it asked for;
//	the INJECTOR itself is graded ("every key injection this run was
//	accepted by xdotool"). This one is here because it was needed: a
//	malformed xdotool option during development made every chord injection
//	fail silently and turned thirteen claims red about the daemon while the
//	fault was in the instrument.
//
// # Both engines, one suite
//
// The same binary drives hotkeyd.py: point $HOTKEYD_BIN at
// `python3 hotkeyd.py` and every daemon-phase scenario runs against the
// python engine instead. Running both is what produced the two findings
// this tool has made so far, and only one of them was about the daemons:
//
//	REAL: the transition log's device= field is `"..."` from Go's %q and
//	`'...'` from python's !r (bd dotfiles-n0r4). Both spellings are parsed
//	so this tool stays engine-neutral; the decision belongs to the parity
//	gate.
//	NOT REAL: Shift+Escape / Shift+Return read as "not obtained" on the
//	python arm only. A direct measurement showed both engines hold them —
//	the probe was sampling a half-installed grab set, because both daemons
//	publish the new layer state BEFORE finishing a one-chord-at-a-time
//	sync, and python's 106-chord sync is slower. Fixed by
//	awaitGrabsSettled (daemonchecks.go). A single-engine run would have
//	shipped that bug as a green suite.
package main
