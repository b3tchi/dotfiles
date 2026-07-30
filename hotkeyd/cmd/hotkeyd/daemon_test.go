package main

// Wiring-deletion coverage for the daemon assembly + run loop (sp021 Task
// 12, bd dotfiles-ylmp.11). dotfiles-eez2 records the exact defect class
// this file exists to close: hotkeyd.py's run_daemon loop was only ever
// driven by a REAL X display, so a dropped dae.pump_i3() call shipped
// green — the unit suite drove pump_i3() directly, never the loop that
// called it. Every test below drives (*Daemon).Run itself, against fakes
// implementing daemon.go's seam interfaces, with NO Xvfb and NO real i3.
// Each "wiring" test is written so that deleting the single line it names
// makes that test fail — see each test's doc for which mutant it kills.

import (
	"encoding/binary"
	"errors"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/i3"
	"hotkeyd/internal/layer"
	"hotkeyd/internal/proc"
	"hotkeyd/internal/x11"
)

// ---------------------------------------------------------------------
// fakes — one per seam interface daemon.go defines
// ---------------------------------------------------------------------

// fakeI3Client implements i3.Client in full (a stub missing a method is a
// compile error here, exactly as the Client doc promises — sp021's
// problem statement item 4, closed structurally).
type fakeI3Client struct {
	mu sync.Mutex

	commandFn      func(string) (bool, string, error)
	getConfigFn    func() (string, error)
	subscribeFn    func(...string) error
	bindingStateFn func() (string, error)
	pollEventsFn   func() (bool, error)
	filenoFn       func() (int, bool)
	closeFn        func() error

	commands       []string
	pollEventCalls int
	subscribed     []string
	closed         bool
}

func (f *fakeI3Client) Command(cmd string) (bool, string, error) {
	f.mu.Lock()
	f.commands = append(f.commands, cmd)
	f.mu.Unlock()
	if f.commandFn != nil {
		return f.commandFn(cmd)
	}
	return true, "", nil
}

func (f *fakeI3Client) GetConfig() (string, error) {
	if f.getConfigFn != nil {
		return f.getConfigFn()
	}
	return "", nil
}

func (f *fakeI3Client) Subscribe(events ...string) error {
	f.mu.Lock()
	f.subscribed = append(f.subscribed, events...)
	f.mu.Unlock()
	if f.subscribeFn != nil {
		return f.subscribeFn(events...)
	}
	return nil
}

func (f *fakeI3Client) BindingState() (string, error) {
	if f.bindingStateFn != nil {
		return f.bindingStateFn()
	}
	return layer.DefaultI3Mode, nil
}

func (f *fakeI3Client) PollEvents() (bool, error) {
	f.mu.Lock()
	f.pollEventCalls++
	f.mu.Unlock()
	if f.pollEventsFn != nil {
		return f.pollEventsFn()
	}
	return false, nil
}

func (f *fakeI3Client) Fileno() (int, bool) {
	if f.filenoFn != nil {
		return f.filenoFn()
	}
	return 0, false
}

func (f *fakeI3Client) Close() error {
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()
	if f.closeFn != nil {
		return f.closeFn()
	}
	return nil
}

func (f *fakeI3Client) pollEventsCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.pollEventCalls
}

func (f *fakeI3Client) commandsSent() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.commands...)
}

var _ i3.Client = (*fakeI3Client)(nil)

// fakeGrabs implements grabSyncer.
type fakeGrabs struct {
	mu sync.Mutex

	syncBindsCalls     [][]string
	mappingNotifyCalls int
	active             map[string]GrabbedChord
	wanted             []string
	grabReportWanted   int
	grabReportActive   int
	grabReportMissing  []string
}

func (f *fakeGrabs) SyncBinds(chords []string) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.syncBindsCalls = append(f.syncBindsCalls, append([]string(nil), chords...))
	return true
}

func (f *fakeGrabs) OnMappingNotify() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.mappingNotifyCalls++
	return true
}

func (f *fakeGrabs) Active() map[string]GrabbedChord {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.active
}

func (f *fakeGrabs) Wanted() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.wanted
}

func (f *fakeGrabs) GrabReport() (int, int, []string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.grabReportWanted, f.grabReportActive, f.grabReportMissing
}

func (f *fakeGrabs) syncCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.syncBindsCalls)
}

func (f *fakeGrabs) mappingNotifyCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.mappingNotifyCalls
}

var _ grabSyncer = (*fakeGrabs)(nil)

// fakeDevices implements deviceAttributor.
type fakeDevices struct {
	mu              sync.Mutex
	invalidateCalls int
	attributeFn     func(x11.DeviceEvent) (string, bool)
}

func (f *fakeDevices) Invalidate() {
	f.mu.Lock()
	f.invalidateCalls++
	f.mu.Unlock()
}

func (f *fakeDevices) AttributeSource(ev x11.DeviceEvent) (string, bool) {
	if f.attributeFn != nil {
		return f.attributeFn(ev)
	}
	return "", false
}

func (f *fakeDevices) invalidateCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.invalidateCalls
}

var _ deviceAttributor = (*fakeDevices)(nil)

// fakeLock implements lockBeater.
type fakeLock struct {
	mu       sync.Mutex
	beats    int
	released bool
}

func (f *fakeLock) Beat() {
	f.mu.Lock()
	f.beats++
	f.mu.Unlock()
}

func (f *fakeLock) Release() {
	f.mu.Lock()
	f.released = true
	f.mu.Unlock()
}

func (f *fakeLock) beatCount() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.beats
}

func (f *fakeLock) wasReleased() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.released
}

var _ lockBeater = (*fakeLock)(nil)

// fakeCloser is a spy io.Closer for the publisher/X-connection shutdown
// seams.
type fakeCloser struct {
	mu     sync.Mutex
	closed bool
	err    error
}

func (f *fakeCloser) Close() error {
	f.mu.Lock()
	f.closed = true
	f.mu.Unlock()
	return f.err
}

func (f *fakeCloser) wasClosed() bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.closed
}

// fakeLogger records every log line for assertions.
type fakeLogger struct {
	mu    sync.Mutex
	lines []string
}

func (f *fakeLogger) log(msg string) {
	f.mu.Lock()
	f.lines = append(f.lines, msg)
	f.mu.Unlock()
}

func (f *fakeLogger) all() []string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return append([]string(nil), f.lines...)
}

func (f *fakeLogger) contains(sub string) bool {
	for _, l := range f.all() {
		if strings.Contains(l, sub) {
			return true
		}
	}
	return false
}

// ---------------------------------------------------------------------
// synthetic XI2 raw event construction — mirrors events.go's
// ParseDeviceEvent decode offsets exactly, in reverse.
// ---------------------------------------------------------------------

func buildXIKeyEventRaw(evType uint16, sourceID uint16, detail, effectiveMods uint32, repeat bool) []byte {
	raw := make([]byte, 80) // fixedLen in events.go, buttons/valuators/axes all empty
	binary.LittleEndian.PutUint16(raw[8:10], evType)
	binary.LittleEndian.PutUint32(raw[16:20], detail)
	binary.LittleEndian.PutUint16(raw[52:54], sourceID)
	var flags uint32
	if repeat {
		flags |= x11.XIKeyRepeat
	}
	binary.LittleEndian.PutUint32(raw[56:60], flags)
	binary.LittleEndian.PutUint32(raw[72:76], effectiveMods) // ModifierState.Effective
	return raw
}

func xiKeyEvent(evType uint16, sourceID uint16, detail, effectiveMods uint32, repeat bool) x11.Event {
	return x11.Event{Code: xiGenericEvent, Raw: buildXIKeyEventRaw(evType, sourceID, detail, effectiveMods, repeat)}
}

func xiHierarchyEvent() x11.Event {
	raw := make([]byte, 80)
	binary.LittleEndian.PutUint16(raw[8:10], xiEvtHierarchyChanged)
	return x11.Event{Code: xiGenericEvent, Raw: raw}
}

func mappingNotifyEvent() x11.Event {
	return x11.Event{Code: coreMappingNotify, Raw: make([]byte, 32)}
}

// ---------------------------------------------------------------------
// test fixture: a small, self-contained bind table (NOT config.go's real
// 70-bind table — daemon wiring tests should not break every time that
// table changes).
// ---------------------------------------------------------------------

func testBinds() []bind.Bind {
	return []bind.Bind{
		{Chord: "a", Actions: []bind.Action{bind.Command("test command a")}},
		{Chord: "b", Actions: []bind.Action{bind.Command("test command b")}, OnRelease: true},
		{Chord: "$mod+o", Actions: []bind.Action{bind.EnterLayer{Layer: "nav"}}},
	}
}

func testLayers() map[string]bind.Layer {
	return map[string]bind.Layer{
		"nav": {
			Binds:    []bind.Bind{{Chord: "h", Actions: []bind.Action{bind.Command("focus left")}}},
			ExitKeys: []string{"q"},
			OnExit:   []bind.Action{bind.Command("nav on_exit")},
		},
	}
}

// harness bundles a Daemon with every fake it was built from, for
// assertions.
type harness struct {
	dae     *Daemon
	events  chan x11.Event
	i3c     *fakeI3Client
	grabs   *fakeGrabs
	devices *fakeDevices
	lock    *fakeLock
	pub     *fakeCloser
	xConn   *fakeCloser
	logger  *fakeLogger
	engine  *layer.Engine

	modQueryCalls int
	modQueryMu    sync.Mutex
	modDown       map[string]bool

	runCalls []string
	runMu    sync.Mutex
	runFn    func(string) error
}

// neverFiresTick is deliberately far longer than any test's run window
// (tests stop the daemon within tens of milliseconds), so the timer
// branch of Run's select CANNOT fire during the test — this is what
// makes an "event branch did X" assertion surgical rather than
// ambiguous: with a short tick, a passing assertion could be satisfied by
// either branch, and a mutant that deletes the call from the EVENT branch
// alone would ship green because the TIMEOUT branch's own (correct) call
// papers over it. See newTimeoutHarness for the complementary case.
const neverFiresTick = 10 * time.Second

// timeoutFiresTick is short enough to fire many times within a test's
// run window, for tests that specifically target the timer branch.
const timeoutFiresTick = 5 * time.Millisecond

func newHarness(t *testing.T) *harness {
	t.Helper()
	return newHarnessWithTicks(t, neverFiresTick, neverFiresTick)
}

// newTimeoutHarness builds a harness whose idle/hold ticks fire quickly,
// for tests that assert something the TIMEOUT branch alone is
// responsible for (pumpI3/Beat/pollIdle called with no X event arriving).
func newTimeoutHarness(t *testing.T) *harness {
	t.Helper()
	return newHarnessWithTicks(t, timeoutFiresTick, timeoutFiresTick)
}

func newHarnessWithTicks(t *testing.T, idleTick, holdTick time.Duration) *harness {
	t.Helper()
	h := &harness{
		events:  make(chan x11.Event, 8),
		i3c:     &fakeI3Client{},
		grabs:   &fakeGrabs{active: map[string]GrabbedChord{}, wanted: []string{}},
		devices: &fakeDevices{},
		lock:    &fakeLock{},
		pub:     &fakeCloser{},
		xConn:   &fakeCloser{},
		logger:  &fakeLogger{},
		modDown: map[string]bool{},
	}
	h.engine = layer.NewEngine(testBinds(), testLayers(), layer.Config{Mod: "Mod4"})

	newModQuery := func() layer.ModifierDown {
		h.modQueryMu.Lock()
		h.modQueryCalls++
		h.modQueryMu.Unlock()
		return func(mod string) (bool, error) {
			h.modQueryMu.Lock()
			defer h.modQueryMu.Unlock()
			return h.modDown[mod], nil
		}
	}

	runFn := func(cmd string) error {
		h.runMu.Lock()
		h.runCalls = append(h.runCalls, cmd)
		fn := h.runFn
		h.runMu.Unlock()
		if fn != nil {
			return fn(cmd)
		}
		return nil
	}

	h.dae = NewDaemon(DaemonConfig{
		Events:      h.events,
		I3:          h.i3c,
		Grabs:       h.grabs,
		Devices:     h.devices,
		Engine:      h.engine,
		Lock:        h.lock,
		Publisher:   h.pub,
		XConn:       h.xConn,
		NewModQuery: newModQuery,
		Run:         runFn,
		Binds:       testBinds(),
		Layers:      testLayers(),
		Mod:         "Mod4",
		Display:     ":99",
		Log:         h.logger.log,
		IdleTick:    idleTick,
		HoldTick:    holdTick,
	})
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	return h
}

// runWithTimeout runs h.dae.Run(sig) on a goroutine and returns its exit
// code, failing the test if Run does not return within timeout — every
// wiring test must terminate the loop itself (send SIGTERM/SIGINT, or
// close the events channel) rather than relying on this as a normal stop
// path.
func runWithTimeout(t *testing.T, h *harness, sig chan os.Signal, timeout time.Duration) int {
	t.Helper()
	done := make(chan int, 1)
	go func() { done <- h.dae.Run(sig) }()
	select {
	case code := <-done:
		return code
	case <-time.After(timeout):
		t.Fatal("Run did not return within timeout — the loop is stuck")
		return -1
	}
}

// ---------------------------------------------------------------------
// Run(): the heart of the wiring-deletion contract. Each test name says
// exactly which call site it kills a mutant on.
// ---------------------------------------------------------------------

func TestRun_TimeoutBranch_PumpsI3(t *testing.T) {
	// Kills: deleting d.pumpI3() from the timer.C case. Uses
	// newTimeoutHarness (short ticks, no events sent) so the ONLY branch
	// that can run during this test is the timer one — with the default
	// (never-firing) harness this assertion would also be satisfied by
	// an event-branch call, papering over a deleted timeout-branch call.
	h := newTimeoutHarness(t)
	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)
	if h.i3c.pollEventsCount() == 0 {
		t.Fatal("PollEvents was never called from the timeout branch — pumpI3() wiring is missing")
	}
}

func TestRun_TimeoutBranch_PollsIdle_ActuallyQueriesWhenHoldLayerActive(t *testing.T) {
	// Kills: deleting d.pollIdle() (and so d.newMod()) from the timer.C
	// case. With a hold layer entered and no X events arriving, PollIdle
	// MUST ask the server every idle tick — the ONLY channel that can
	// observe the hold modifier's release (adr0016).
	h := newTimeoutHarness(t)
	binds := []bind.Bind{{Chord: "$mod+Tab", Actions: []bind.Action{bind.EnterLayer{Layer: "sw"}}}}
	layers := map[string]bind.Layer{
		"sw": {Hold: "$mod", ExitKeys: []string{"q"}},
	}
	h.engine = layer.NewEngine(binds, layers, layer.Config{Mod: "Mod4"})
	h.dae = NewDaemon(DaemonConfig{
		Events: h.events, I3: h.i3c, Grabs: h.grabs, Devices: h.devices,
		Engine: h.engine, Lock: h.lock, Publisher: h.pub, XConn: h.xConn,
		NewModQuery: func() layer.ModifierDown {
			h.modQueryMu.Lock()
			h.modQueryCalls++
			h.modQueryMu.Unlock()
			return func(string) (bool, error) { return true, nil } // still held
		},
		Run:   func(string) error { return nil },
		Binds: binds, Layers: layers, Mod: "Mod4", Display: ":99",
		Log: h.logger.log, IdleTick: timeoutFiresTick, HoldTick: timeoutFiresTick,
	})
	h.engine.Handle(layer.Event{Kind: layer.Press, Key: "Tab", Mods: map[string]bool{"Mod4": true}})
	if h.engine.HoldModifier() == "" {
		t.Fatal("fixture bug: hold layer did not activate")
	}

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)

	h.modQueryMu.Lock()
	calls := h.modQueryCalls
	h.modQueryMu.Unlock()
	if calls == 0 {
		t.Fatal("NewModQuery was never invoked from the timeout branch — pollIdle() wiring is missing")
	}
}

func TestRun_EventBranch_PumpsI3(t *testing.T) {
	// Kills: deleting d.pumpI3() from the events case — the exact
	// dotfiles-eez2 mutant (M3: delete dae.pump_i3() from the loop body).
	h := newHarness(t)
	h.events <- mappingNotifyEvent()
	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)
	if h.i3c.pollEventsCount() == 0 {
		t.Fatal("PollEvents was never called from the event branch — pumpI3() wiring is missing")
	}
}

func TestRun_EventBranch_BeatsHeartbeat(t *testing.T) {
	// Kills: deleting d.lock.Beat() from the events case.
	h := newHarness(t)
	h.events <- mappingNotifyEvent()
	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(20 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)
	if h.lock.beatCount() == 0 {
		t.Fatal("Beat() was never called — heartbeat wiring is missing")
	}
}

func TestRun_KeyPress_DispatchesMatchedCommand(t *testing.T) {
	// Kills: deleting d.handleXEvent(ev) (or its internal dispatch call)
	// from the events case — a full press -> match -> dispatch cycle,
	// scripted end to end against fakes.
	h := newHarness(t)
	h.grabs.wanted = []string{"a"}
	h.grabs.active = map[string]GrabbedChord{"a": {Code: 38, Mask: 0}}

	h.events <- xiKeyEvent(xiEvtKeyPress, 7, 38, 0, false)

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)

	cmds := h.i3c.commandsSent()
	found := false
	for _, c := range cmds {
		if c == "test command a" {
			found = true
		}
	}
	if !found {
		t.Fatalf("i3 Command never received the dispatched action; commands=%v", cmds)
	}
}

func TestRun_KeyPress_LayerChange_ResyncsGrabs(t *testing.T) {
	// Kills: deleting the `if d.engine.State().Layer != before { d.resyncGrabs() }`
	// call from handleKeyEvent — a layer entered but never re-grabbed
	// would leave its bare keys ungrabbed, silently dead
	// (dotfiles-hwds.41's failure shape, one level up).
	h := newHarness(t)
	// testBinds' "$mod+o" enters the "nav" layer.
	h.grabs.wanted = []string{"$mod+o"}
	h.grabs.active = map[string]GrabbedChord{"$mod+o": {Code: 32, Mask: maskMod4}}

	h.events <- xiKeyEvent(xiEvtKeyPress, 7, 32, maskMod4, false)

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)

	if h.engine.State().Layer != "nav" {
		t.Fatalf("fixture bug: engine did not enter nav (state=%+v)", h.engine.State())
	}
	if h.grabs.syncCount() == 0 {
		t.Fatal("SyncBinds was never called after a layer transition — resyncGrabs() wiring is missing")
	}
	last := h.grabs.syncBindsCalls[len(h.grabs.syncBindsCalls)-1]
	if !containsStr(last, "h") {
		t.Fatalf("resync after entering nav did not ask for its own bind %q; got %v", "h", last)
	}
}

func TestRun_KeyRelease_OnReleaseBindFires(t *testing.T) {
	h := newHarness(t)
	h.grabs.wanted = []string{"b"}
	h.grabs.active = map[string]GrabbedChord{"b": {Code: 56, Mask: 0}}

	// A release the engine never saw a press for is an "orphan release"
	// and is dropped (dotfiles-hwds.24) — press first, then release.
	h.events <- xiKeyEvent(xiEvtKeyPress, 7, 56, 0, false)
	h.events <- xiKeyEvent(xiEvtKeyRelease, 7, 56, 0, false)

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)

	cmds := h.i3c.commandsSent()
	found := false
	for _, c := range cmds {
		if c == "test command b" {
			found = true
		}
	}
	if !found {
		t.Fatalf("on_release bind never fired; commands=%v", cmds)
	}
}

func TestRun_KeyPress_RepeatIsSwallowed(t *testing.T) {
	h := newHarness(t)
	h.grabs.wanted = []string{"a"}
	h.grabs.active = map[string]GrabbedChord{"a": {Code: 38, Mask: 0}}
	h.events <- xiKeyEvent(xiEvtKeyPress, 7, 38, 0, true) // XIKeyRepeat set

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)

	if len(h.i3c.commandsSent()) != 0 {
		t.Fatalf("a repeat-flagged press dispatched an action; commands=%v", h.i3c.commandsSent())
	}
}

func TestRun_KeyPress_IgnoredDeviceIsDropped(t *testing.T) {
	orig := bind.IgnoreDevices
	bind.IgnoreDevices = []string{"xtest-fake"}
	t.Cleanup(func() { bind.IgnoreDevices = orig })

	h := newHarness(t)
	h.grabs.wanted = []string{"a"}
	h.grabs.active = map[string]GrabbedChord{"a": {Code: 38, Mask: 0}}
	h.devices.attributeFn = func(x11.DeviceEvent) (string, bool) { return "xtest-fake", true }
	h.events <- xiKeyEvent(xiEvtKeyPress, 7, 38, 0, false)

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)

	if len(h.i3c.commandsSent()) != 0 {
		t.Fatalf("an IGNORE_DEVICES-listed source dispatched an action; commands=%v", h.i3c.commandsSent())
	}
}

func TestRun_MappingNotify_ResyncsGrabsAndPublishesReport(t *testing.T) {
	// Kills: deleting d.grabs.OnMappingNotify() OR the report-publish call
	// from the MappingNotify branch.
	h := newHarness(t)
	h.grabs.grabReportWanted, h.grabs.grabReportActive = 3, 2
	h.grabs.grabReportMissing = []string{"$mod+z"}
	h.events <- mappingNotifyEvent()

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)

	if h.grabs.mappingNotifyCount() == 0 {
		t.Fatal("OnMappingNotify was never called")
	}
	report, ok := proc.ReadGrabReport(":99")
	if !ok {
		t.Fatal("grab report was never published to disk")
	}
	if report.Wanted != 3 || report.Active != 2 || len(report.Missing) != 1 {
		t.Fatalf("grab report = %+v, want wanted=3 active=2 missing=[$mod+z]", report)
	}
}

func TestRun_HierarchyChanged_InvalidatesDeviceRegistry(t *testing.T) {
	// Kills: deleting d.devices.Invalidate() from the hierarchy/device
	// branch.
	h := newHarness(t)
	h.events <- xiHierarchyEvent()

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 2*time.Second)

	if h.devices.invalidateCount() == 0 {
		t.Fatal("Invalidate was never called for a hierarchy-changed event")
	}
}

func TestRun_SIGHUP_LogsNamedReplacement_AndDoesNotStop(t *testing.T) {
	// Kills: deleting the SIGHUP branch (or collapsing it into the
	// stop branch) — a daemon that stops on SIGHUP is a regression, not a
	// no-op.
	h := newHarness(t)
	sig := make(chan os.Signal, 1)
	sig <- syscall.SIGHUP

	// Give the loop a moment to observe SIGHUP and keep running, then
	// prove it is STILL alive by feeding a normal event that must still
	// dispatch, before finally stopping it.
	go func() {
		time.Sleep(20 * time.Millisecond)
		h.grabs.wanted = []string{"a"}
		h.grabs.active = map[string]GrabbedChord{"a": {Code: 38, Mask: 0}}
		h.events <- xiKeyEvent(xiEvtKeyPress, 7, 38, 0, false)
		time.Sleep(20 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	code := runWithTimeout(t, h, sig, 2*time.Second)
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
	if !h.logger.contains("hotkeyd.sh restart") {
		t.Fatalf("SIGHUP did not log the named replacement; log lines: %v", h.logger.all())
	}
	if len(h.i3c.commandsSent()) == 0 {
		t.Fatal("daemon stopped serving after SIGHUP instead of continuing")
	}
}

func TestRun_SIGTERM_RunsFullShutdownSequence(t *testing.T) {
	// Kills: deleting ANY line inside shutdown() — dispatch of
	// ShutdownActions, publisher Close, i3 Close, X Close, or lock
	// Release.
	h := newHarness(t)
	// Enter the nav layer so ShutdownActions() has something to say
	// (OnExit: "nav on_exit") — an idle daemon's shutdown is silent by
	// design, so this drives the non-trivial path.
	h.engine.Handle(layer.Event{Kind: layer.Press, Key: "o", Mods: map[string]bool{"Mod4": true}})
	if h.engine.State().Layer != "nav" {
		t.Fatal("fixture bug: nav layer did not activate")
	}

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(20 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	code := runWithTimeout(t, h, sig, 2*time.Second)

	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
	found := false
	for _, c := range h.i3c.commandsSent() {
		if c == "nav on_exit" {
			found = true
		}
	}
	if !found {
		t.Errorf("ShutdownActions (on_exit) was not dispatched; commands=%v", h.i3c.commandsSent())
	}
	if !h.pub.wasClosed() {
		t.Error("publisher was not closed on shutdown")
	}
	if !h.i3c.closed {
		t.Error("i3 client was not closed on shutdown")
	}
	if !h.xConn.wasClosed() {
		t.Error("X connection was not closed on shutdown")
	}
	if !h.lock.wasReleased() {
		t.Error("lock was not released on shutdown")
	}
}

func TestRun_SIGINT_StopsCleanly(t *testing.T) {
	h := newHarness(t)
	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(15 * time.Millisecond)
		sig <- syscall.SIGINT
	}()
	code := runWithTimeout(t, h, sig, 2*time.Second)
	if code != 0 {
		t.Fatalf("exit code = %d, want 0", code)
	}
	if !h.lock.wasReleased() {
		t.Error("SIGINT did not run the shutdown sequence")
	}
}

func TestRun_XEventsChannelClosed_ReturnsFatalNamedExit(t *testing.T) {
	// Kills: deleting the `!ok` handling for a closed events channel
	// (the edge case "X server death mid-run: fatal named exit").
	h := newHarness(t)
	close(h.events)
	sig := make(chan os.Signal, 1)
	code := runWithTimeout(t, h, sig, 2*time.Second)
	if code != exitXConnLost {
		t.Fatalf("exit code = %d, want %d (exitXConnLost)", code, exitXConnLost)
	}
	if !h.logger.contains("X connection lost") {
		t.Errorf("closed events channel did not log a named message; log lines: %v", h.logger.all())
	}
	// Still a clean shutdown, not a crash.
	if !h.lock.wasReleased() {
		t.Error("lock was not released after a fatal X-death exit")
	}
}

func TestRun_EventFlood_DoesNotStarveHeartbeat(t *testing.T) {
	// Edge case: an auto-repeat storm must not starve the heartbeat.
	// Beat() is called on EVERY event-branch iteration (see the event
	// case in Run), so a flood proves this trivially — this test exists
	// to name that property explicitly and catch a regression that moves
	// Beat() off the hot path.
	h := newHarness(t)
	h.grabs.wanted = []string{"a"}
	h.grabs.active = map[string]GrabbedChord{"a": {Code: 38, Mask: 0}}
	go func() {
		for i := 0; i < 50; i++ {
			h.events <- xiKeyEvent(xiEvtKeyPress, 7, 38, 0, true) // repeat: swallowed, still beats
		}
	}()
	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(60 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	runWithTimeout(t, h, sig, 3*time.Second)
	if h.lock.beatCount() == 0 {
		t.Fatal("heartbeat starved during an event flood")
	}
}

func TestRun_ActionSpawnFailing_LoggedAndLoopContinues(t *testing.T) {
	// Edge case: "Action spawn failing (run target missing) -> logged,
	// loop continues."
	h := newHarness(t)
	h.runFn = func(string) error { return errors.New("boom: exec: no such file") }
	h.grabs.wanted = []string{"a"}
	h.grabs.active = map[string]GrabbedChord{"a": {Code: 38, Mask: 0}}
	// Swap "a" to a Run action for this test via a fresh engine.
	binds := []bind.Bind{{Chord: "a", Actions: []bind.Action{bind.Run{Cmd: "nonexistent-thing"}}}}
	h.engine = layer.NewEngine(binds, map[string]bind.Layer{}, layer.Config{Mod: "Mod4"})
	h.dae = NewDaemon(DaemonConfig{
		Events: h.events, I3: h.i3c, Grabs: h.grabs, Devices: h.devices,
		Engine: h.engine, Lock: h.lock, Publisher: h.pub, XConn: h.xConn,
		NewModQuery: func() layer.ModifierDown { return func(string) (bool, error) { return false, nil } },
		Run:         h.runFn,
		Binds:       binds, Layers: map[string]bind.Layer{}, Mod: "Mod4", Display: ":99",
		Log: h.logger.log, IdleTick: 5 * time.Millisecond, HoldTick: 2 * time.Millisecond,
	})

	h.events <- xiKeyEvent(xiEvtKeyPress, 7, 38, 0, false)
	// A second, harmless event proves the loop is still turning after the
	// failure.
	h.events <- mappingNotifyEvent()

	sig := make(chan os.Signal, 1)
	go func() {
		time.Sleep(30 * time.Millisecond)
		sig <- syscall.SIGTERM
	}()
	code := runWithTimeout(t, h, sig, 2*time.Second)
	if code != 0 {
		t.Fatalf("a failed spawn took the daemon down: exit code = %d", code)
	}
	if !h.logger.contains("boom") {
		t.Errorf("spawn failure was not logged; log lines: %v", h.logger.all())
	}
}

func TestRun_RealOSSignal_SIGTERM_StopsViaProcessSelfSignal(t *testing.T) {
	// The literal "signal-handling test via process self-signal" from
	// this task's test_plan: wires signal.Notify for real (as main.go
	// does) and sends this PROCESS an actual SIGTERM, proving the OS
	// plumbing (not just the channel-select logic above) works.
	h := newHarness(t)
	sig := make(chan os.Signal, 1)
	realSignalNotify(t, sig)

	done := make(chan int, 1)
	go func() { done <- h.dae.Run(sig) }()

	time.Sleep(20 * time.Millisecond)
	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatalf("self-signal: %v", err)
	}

	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("exit code = %d, want 0", code)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("Run did not react to a real SIGTERM sent to this process")
	}
}

// ---------------------------------------------------------------------
// pure helpers — chord-set derivation, keysym resolution, mask decoding
// ---------------------------------------------------------------------

func TestChordsFor_DefaultLayer_IsGlobalOnly(t *testing.T) {
	got := chordsFor(testBinds(), testLayers(), layer.DefaultLayer, "Mod4")
	want := []string{"a", "b", "$mod+o"}
	if !equalStrs(got, want) {
		t.Fatalf("chordsFor(default) = %v, want %v", got, want)
	}
}

func TestChordsFor_ActiveLayer_AddsLayerChords(t *testing.T) {
	got := chordsFor(testBinds(), testLayers(), "nav", "Mod4")
	if !containsStr(got, "h") {
		t.Errorf("chordsFor(nav) = %v, missing the layer's own bind %q", got, "h")
	}
	if !containsStr(got, "q") {
		t.Errorf("chordsFor(nav) = %v, missing the exit key %q", got, "q")
	}
	// Every listed EXIT_MODIFIER not otherwise routed gets a modifier-held
	// variant of every exit key.
	if !containsStr(got, "Shift+q") || !containsStr(got, "Ctrl+q") || !containsStr(got, "Mod1+q") {
		t.Errorf("chordsFor(nav) = %v, missing modifier-held exit-key variants", got)
	}
}

func TestChordsFor_UnknownLayer_IsGlobalOnly(t *testing.T) {
	got := chordsFor(testBinds(), testLayers(), "does-not-exist", "Mod4")
	want := []string{"a", "b", "$mod+o"}
	if !equalStrs(got, want) {
		t.Fatalf("chordsFor(unknown) = %v, want %v", got, want)
	}
}

func TestLayerChords_HoldLayer_GrabsKeysUnderHoldMaskAndSkipsOwnKeysyms(t *testing.T) {
	lay := bind.Layer{
		Binds:    []bind.Bind{{Chord: "Tab", Actions: []bind.Action{bind.Command("next")}}},
		ExitKeys: []string{"q"},
		Hold:     "$mod",
	}
	got := layerChords(lay, "Mod4")
	if !containsStr(got, "Tab") {
		t.Errorf("missing bare Tab: %v", got)
	}
	if !containsStr(got, "Mod4+Tab") {
		t.Errorf("missing hold-masked Mod4+Tab: %v", got)
	}
	if !containsStr(got, "Mod4+q") {
		t.Errorf("missing hold-masked exit key Mod4+q: %v", got)
	}
	// The hold modifier's own keysyms are NEVER grabbed (adr0016: there
	// is nothing to catch, the release is observed by asking the server).
	for _, ks := range modKeysymNames["Mod4"] {
		if containsStr(got, ks) {
			t.Errorf("hold modifier's own keysym %q was grabbed; adr0016 forbids this", ks)
		}
	}
}

func TestLayerChords_DisplayQualifiedBind_ExcludedOnOtherDisplay(t *testing.T) {
	lay := bind.Layer{
		Binds: []bind.Bind{
			{Chord: "x", Actions: []bind.Action{bind.Command("x")}, DisplayMod: "Mod1"},
		},
		ExitKeys: []string{"q"},
	}
	got := layerChords(lay, "Mod4")
	if containsStr(got, "x") {
		t.Errorf("a Mod1-qualified bind was included while resolving for Mod4: %v", got)
	}
	got2 := layerChords(lay, "Mod1")
	if !containsStr(got2, "x") {
		t.Errorf("a Mod1-qualified bind was excluded while resolving for Mod1: %v", got2)
	}
}

func TestGlobalChords_DisplayQualifiedBind_ExcludedOnOtherDisplay(t *testing.T) {
	binds := []bind.Bind{
		{Chord: "x", Actions: []bind.Action{bind.Command("x")}, DisplayMod: "Mod1"},
		{Chord: "y", Actions: []bind.Action{bind.Command("y")}},
	}
	got := globalChords(binds, "Mod4")
	if containsStr(got, "x") {
		t.Errorf("Mod1-qualified bind leaked into a Mod4 grab set: %v", got)
	}
	if !containsStr(got, "y") {
		t.Errorf("unqualified bind missing: %v", got)
	}
}

func TestKeysymFor_PrefersMaskMatch_FallsBackToCodeOnly(t *testing.T) {
	wanted := []string{"Tab", "$mod+Shift+Tab"}
	active := map[string]GrabbedChord{
		"Tab":            {Code: 23, Mask: 0},
		"$mod+Shift+Tab": {Code: 23, Mask: maskShift | maskMod4},
	}
	key, ok := keysymFor(wanted, active, "Mod4", 23, maskShift|maskMod4)
	if !ok || key != "Tab" {
		t.Fatalf("keysymFor(mask match) = (%q, %v), want (Tab, true)", key, ok)
	}
	key, ok = keysymFor(wanted, active, "Mod4", 23, 0)
	if !ok || key != "Tab" {
		t.Fatalf("keysymFor(bare) = (%q, %v), want (Tab, true)", key, ok)
	}
	key, ok = keysymFor(wanted, active, "Mod4", 23, maskCtrl) // no exact mask match -> code-only fallback
	if !ok || key != "Tab" {
		t.Fatalf("keysymFor(fallback) = (%q, %v), want (Tab, true)", key, ok)
	}
}

func TestKeysymFor_NoMatch_ReturnsFalse(t *testing.T) {
	_, ok := keysymFor(nil, map[string]GrabbedChord{}, "Mod4", 99, 0)
	if ok {
		t.Fatal("keysymFor matched against an empty grab set")
	}
}

func TestKeysymFor_IgnoresLockBitsInState(t *testing.T) {
	wanted := []string{"a"}
	active := map[string]GrabbedChord{"a": {Code: 38, Mask: 0}}
	key, ok := keysymFor(wanted, active, "Mod4", 38, x11.ModMaskLock|x11.ModMaskMod2)
	if !ok || key != "a" {
		t.Fatalf("keysymFor with only lock bits set = (%q, %v), want (a, true)", key, ok)
	}
}

func TestModsFromMask_DropsLockBits(t *testing.T) {
	got := modsFromMask(maskShift | maskCtrl | x11.ModMaskLock | x11.ModMaskMod2)
	want := map[string]bool{"Shift": true, "Ctrl": true}
	if len(got) != len(want) || !got["Shift"] || !got["Ctrl"] {
		t.Fatalf("modsFromMask = %v, want %v", got, want)
	}
	if got["Lock"] || got["Mod2"] {
		t.Fatalf("modsFromMask leaked a lock bit: %v", got)
	}
}

func TestModsFromMask_Empty(t *testing.T) {
	got := modsFromMask(0)
	if len(got) != 0 {
		t.Fatalf("modsFromMask(0) = %v, want empty", got)
	}
}

func TestDeviceIgnored(t *testing.T) {
	orig := bind.IgnoreDevices
	defer func() { bind.IgnoreDevices = orig }()

	bind.IgnoreDevices = nil
	if deviceIgnored("") || deviceIgnored("anything") {
		t.Fatal("IGNORE_DEVICES ships EMPTY, yet something was reported ignored")
	}

	bind.IgnoreDevices = []string{"xtest-fake"}
	if !deviceIgnored("xtest-fake") {
		t.Fatal("a listed device was not reported ignored")
	}
	if deviceIgnored("Virtual core keyboard") {
		t.Fatal("an unlisted device was reported ignored")
	}
}

// ---------------------------------------------------------------------
// startup helpers — validateTable, requireXI2, i3SocketResolver,
// buildPublisher, newPointerModifierQuery
// ---------------------------------------------------------------------

func TestValidateTable_ValidTable_ReturnsNil(t *testing.T) {
	if err := validateTable(testBinds(), testLayers(), "Mod4"); err != nil {
		t.Fatalf("validateTable(valid) = %v, want nil", err)
	}
}

func TestValidateTable_InvalidTable_RefusedByName(t *testing.T) {
	// us019 AC: refused by name, daemon does not start on an invalid
	// table. Two binds sharing one chord is the textbook rejection.
	binds := []bind.Bind{
		{Chord: "a", Actions: []bind.Action{bind.Command("one")}},
		{Chord: "a", Actions: []bind.Action{bind.Command("two")}},
	}
	err := validateTable(binds, map[string]bind.Layer{}, "Mod4")
	if err == nil {
		t.Fatal("validateTable(duplicate chord) = nil, want a named error")
	}
	if !strings.Contains(err.Error(), `"a"`) {
		t.Errorf("error does not name the offending chord: %v", err)
	}
}

type fakeXIVersionSource struct {
	extInfo    x11.ExtensionInfo
	extErr     error
	version    x11.XIVersion
	versionErr error
}

func (f fakeXIVersionSource) QueryExtension(string) (x11.ExtensionInfo, error) {
	return f.extInfo, f.extErr
}

func (f fakeXIVersionSource) XIQueryVersion(byte, uint16, uint16) (x11.XIVersion, error) {
	return f.version, f.versionErr
}

func TestRequireXI2_Success(t *testing.T) {
	src := fakeXIVersionSource{
		extInfo: x11.ExtensionInfo{Present: true, MajorOpcode: 130},
		version: x11.XIVersion{Major: 2, Minor: 3},
	}
	if _, err := requireXI2(src); err != nil {
		t.Fatalf("requireXI2 = %v, want nil", err)
	}
}

func TestRequireXI2_NotPresent_NamedError(t *testing.T) {
	src := fakeXIVersionSource{extInfo: x11.ExtensionInfo{Present: false}}
	_, err := requireXI2(src)
	if err == nil || !strings.Contains(err.Error(), "no XInputExtension") {
		t.Fatalf("requireXI2(absent) = %v, want a named 'no XInputExtension' error", err)
	}
}

func TestRequireXI2_QueryExtensionFails_NamedError(t *testing.T) {
	src := fakeXIVersionSource{extErr: errors.New("boom")}
	_, err := requireXI2(src)
	if err == nil || !strings.Contains(err.Error(), "cannot query") {
		t.Fatalf("requireXI2(query failure) = %v, want a named error", err)
	}
}

func TestRequireXI2_OldVersion_NamedError(t *testing.T) {
	src := fakeXIVersionSource{
		extInfo: x11.ExtensionInfo{Present: true, MajorOpcode: 130},
		version: x11.XIVersion{Major: 1, Minor: 0},
	}
	_, err := requireXI2(src)
	if err == nil || !strings.Contains(err.Error(), "XInput 1.0") {
		t.Fatalf("requireXI2(v1) = %v, want a named version error", err)
	}
}

func TestI3SocketResolver_OverrideWins_NeverReadsI3SOCK(t *testing.T) {
	t.Setenv("HOTKEYD_I3SOCK", "/tmp/override.sock")
	t.Setenv("I3SOCK", "/tmp/wrong-display.sock")
	path, err := i3SocketResolver(":10")()
	if err != nil {
		t.Fatalf("i3SocketResolver: %v", err)
	}
	if path != "/tmp/override.sock" {
		t.Fatalf("path = %q, want the HOTKEYD_I3SOCK override", path)
	}
}

func TestI3SocketResolver_ScrubsI3SOCK_PinsOwnDisplay(t *testing.T) {
	// A fake `i3` binary on PATH that proves the resolver (a) never
	// forwards $I3SOCK and (b) pins $DISPLAY to the display THIS
	// resolver was built for, not whatever the ambient environment says
	// — the cross-display-safety property named in this task's bd notes.
	dir := t.TempDir()
	script := "#!/bin/sh\n" +
		"if [ -n \"$I3SOCK\" ]; then echo \"I3SOCK leaked: $I3SOCK\" >&2; exit 1; fi\n" +
		"echo \"/run/i3-$DISPLAY.sock\"\n"
	fakeI3 := filepath.Join(dir, "i3")
	if err := os.WriteFile(fakeI3, []byte(script), 0o755); err != nil {
		t.Fatalf("writing fake i3: %v", err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	t.Setenv("I3SOCK", "/tmp/ambient-wrong.sock")
	t.Setenv("DISPLAY", ":0") // ambient display -- must NOT leak into the resolved path
	os.Unsetenv("HOTKEYD_I3SOCK")

	path, err := i3SocketResolver(":10")()
	if err != nil {
		t.Fatalf("i3SocketResolver: %v", err)
	}
	if path != "/run/i3-:10.sock" {
		t.Fatalf("path = %q, want a socket pinned to :10 (the resolver's own display), not the ambient $DISPLAY", path)
	}
}

func TestBuildPublisher_ChannelUnavailable_LogsAndReturnsNilPublisher(t *testing.T) {
	logger := &fakeLogger{}
	// A display tag whose runtime dir does not exist -> ErrChannelUnavailable.
	t.Setenv("XDG_RUNTIME_DIR", filepath.Join(t.TempDir(), "does-not-exist"))
	pub, closer := buildPublisher(":123", logger.log)
	if pub != nil || closer != nil {
		t.Fatalf("buildPublisher(unavailable) = (%v, %v), want (nil, nil)", pub, closer)
	}
	if !logger.contains("continuing without a state feed") {
		t.Errorf("policy log line missing; got: %v", logger.all())
	}
}

func TestBuildPublisher_Success_ReturnsWorkingPublisher(t *testing.T) {
	logger := &fakeLogger{}
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())
	pub, closer := buildPublisher(":124", logger.log)
	if pub == nil || closer == nil {
		t.Fatalf("buildPublisher(available) = (%v, %v), want non-nil", pub, closer)
	}
	defer closer.Close()
	// Real behavioural check, not just non-nil: Publish must not panic
	// and the socket file must exist.
	pub.Publish(layer.State{Layer: "nav"})
	if _, err := os.Stat(layer.SocketPath(":124")); err != nil {
		t.Errorf("socket file missing after a successful buildPublisher: %v", err)
	}
}

func TestNewPointerModifierQuery_CachesSingleRoundTripPerFactoryCall(t *testing.T) {
	calls := 0
	fake := fakePointerQuerierFunc(func(uint32) (x11.PointerInfo, error) {
		calls++
		return x11.PointerInfo{Mask: uint16(maskShift | maskMod4)}, nil
	})
	factory := newPointerModifierQuery(fake, 1)

	q := factory()
	shift, err := q("Shift")
	if err != nil || !shift {
		t.Fatalf("q(Shift) = (%v, %v), want (true, nil)", shift, err)
	}
	ctrl, err := q("Ctrl")
	if err != nil || ctrl {
		t.Fatalf("q(Ctrl) = (%v, %v), want (false, nil)", ctrl, err)
	}
	if calls != 1 {
		t.Fatalf("QueryPointer called %d times for one factory instance, want exactly 1", calls)
	}

	// A FRESH factory call gets a fresh round trip.
	q2 := factory()
	if _, err := q2("Shift"); err != nil {
		t.Fatalf("q2(Shift): %v", err)
	}
	if calls != 2 {
		t.Fatalf("QueryPointer called %d times after a second factory call, want exactly 2", calls)
	}
}

func TestNewPointerModifierQuery_PropagatesQueryError(t *testing.T) {
	fake := fakePointerQuerierFunc(func(uint32) (x11.PointerInfo, error) {
		return x11.PointerInfo{}, errors.New("boom")
	})
	q := newPointerModifierQuery(fake, 1)()
	if _, err := q("Shift"); err == nil {
		t.Fatal("newPointerModifierQuery swallowed a QueryPointer error")
	}
}

func TestNewPointerModifierQuery_UnknownModifier_NamedError(t *testing.T) {
	fake := fakePointerQuerierFunc(func(uint32) (x11.PointerInfo, error) {
		return x11.PointerInfo{}, nil
	})
	q := newPointerModifierQuery(fake, 1)()
	if _, err := q("NotAModifier"); err == nil {
		t.Fatal("an unknown modifier name did not produce an error")
	}
}

type fakePointerQuerierFunc func(uint32) (x11.PointerInfo, error)

func (f fakePointerQuerierFunc) QueryPointer(window uint32) (x11.PointerInfo, error) {
	return f(window)
}

var _ pointerQuerier = fakePointerQuerierFunc(nil)

// ---------------------------------------------------------------------
// small local helpers
// ---------------------------------------------------------------------

func equalStrs(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// realSignalNotify wires os/signal for real, exactly as main.go's run()
// does, and unregisters it on test cleanup so it cannot leak into other
// tests in this package.
func realSignalNotify(t *testing.T, sig chan os.Signal) {
	t.Helper()
	signal.Notify(sig, syscall.SIGHUP, syscall.SIGTERM, syscall.SIGINT)
	t.Cleanup(func() { signal.Stop(sig) })
}

// ---------------------------------------------------------------------
// Integration smoke: real Xvfb + real i3, start -> chord -> i3 command
// observed -> clean SIGTERM (this task's test_plan, verbatim). Everything
// above this point proves the WIRING with fakes and zero Xvfb; this is
// the one test that proves main.go's actual startup sequence (X connect,
// XI2 probe, lock, mod resolution, table validation, initial grab, i3
// subscribe) composes correctly against the real thing. Skips cleanly if
// Xvfb/i3/xdotool are not on PATH.
// ---------------------------------------------------------------------

func requireBinary(t *testing.T, name string) {
	t.Helper()
	if _, err := exec.LookPath(name); err != nil {
		t.Skipf("%s not available on PATH: %v", name, err)
	}
}

func waitForPathIntegration(path string, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}

func TestIntegration_StartChordDispatchCleanShutdown_Xvfb(t *testing.T) {
	requireBinary(t, "Xvfb")
	requireBinary(t, "i3")
	requireBinary(t, "xdotool")

	const display = ":198" // an unusual number: siblings may also run Xvfb concurrently
	sockPath := filepath.Join(t.TempDir(), "i3ipc-hotkeyd-integration.sock")
	i3CfgPath := filepath.Join(t.TempDir(), "i3-hotkeyd-integration.conf")
	if err := os.WriteFile(i3CfgPath,
		[]byte("font pango:monospace 10\nipc-socket "+sockPath+"\n"), 0o644); err != nil {
		t.Fatalf("writing i3 config: %v", err)
	}

	xvfb := exec.Command("Xvfb", display, "-screen", "0", "800x600x24", "-nolisten", "tcp")
	if err := xvfb.Start(); err != nil {
		t.Fatalf("starting Xvfb: %v", err)
	}
	t.Cleanup(func() { xvfb.Process.Kill(); xvfb.Wait() })
	if !waitForPathIntegration("/tmp/.X11-unix/X198", 5*time.Second) {
		t.Fatal("Xvfb did not create its socket in time")
	}

	i3Cmd := exec.Command("i3", "-c", i3CfgPath)
	i3Cmd.Env = append(os.Environ(), "DISPLAY="+display)
	if err := i3Cmd.Start(); err != nil {
		t.Fatalf("starting i3: %v", err)
	}
	t.Cleanup(func() { i3Cmd.Process.Kill(); i3Cmd.Wait() })
	if !waitForPathIntegration(sockPath, 5*time.Second) {
		t.Fatal("i3 did not create its IPC socket in time")
	}

	// Bare Xvfb accepts unauthenticated connections -- point XAUTHORITY at
	// a nonexistent file so x11.Open never tries a stale cookie (mirrors
	// internal/x11's TestOpen_Xvfb_Bare rig).
	t.Setenv("XAUTHORITY", filepath.Join(t.TempDir(), "nonexistent-Xauthority"))
	t.Setenv("DISPLAY", display)
	runtimeDir := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", runtimeDir)
	t.Setenv("HOTKEYD_I3SOCK", sockPath) // pin i3SocketResolver, never $I3SOCK

	// A minimal, self-contained table for this smoke test rather than
	// config.go's shipped 70-bind table: several of its Run actions spawn
	// scripts (ws-switch.nu, quickshell) that do not exist in this test
	// environment, and this test's job is proving the WIRING, not the
	// shipped table's content (config_test.go already covers that).
	marker := filepath.Join(t.TempDir(), "hotkeyd-integration-fired")
	origBinds, origLayers := Binds, Layers
	Binds = []bind.Bind{
		{Chord: "$mod+z", Actions: []bind.Action{bind.Command("exec --no-startup-id touch " + marker)}},
	}
	Layers = map[string]bind.Layer{}
	t.Cleanup(func() { Binds, Layers = origBinds, origLayers })

	done := make(chan int, 1)
	go func() { done <- run([]string{"--display", display}) }()

	if !waitForPathIntegration(proc.LockPath(display), 5*time.Second) {
		t.Fatal("daemon did not start (no lock file appeared) -- startup wiring is broken")
	}
	// Give the grab a moment to land before injecting the chord.
	if !waitForGrabReportActive(display, 1, 5*time.Second) {
		t.Fatal("daemon never reported an active grab -- initial SyncBinds wiring is broken")
	}

	cmd := exec.Command("xdotool", "key", "--clearmodifiers", "super+z")
	cmd.Env = append(os.Environ(), "DISPLAY="+display)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("xdotool key super+z: %v: %s", err, out)
	}

	if !waitForPathIntegration(marker, 5*time.Second) {
		t.Fatal("chord did not reach i3 (or i3 did not spawn the marker) -- press-to-i3-dispatch pipeline is broken")
	}

	if err := syscall.Kill(os.Getpid(), syscall.SIGTERM); err != nil {
		t.Fatalf("self-signal SIGTERM: %v", err)
	}
	select {
	case code := <-done:
		if code != 0 {
			t.Fatalf("run() exit code = %d, want 0 (clean SIGTERM shutdown)", code)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("daemon did not shut down within 5s of SIGTERM")
	}

	if _, err := os.Stat(proc.LockPath(display)); err == nil {
		// The lock FILE persists (Release only unlocks + closes the fd,
		// matching proc.Lock.Release's doc) -- what must be verified is
		// that the flock itself was released, i.e. a fresh AcquireLock
		// now succeeds.
		l, err := proc.AcquireLock(proc.LockPath(display))
		if err != nil {
			t.Fatalf("lock was not released on shutdown: %v", err)
		}
		l.Release()
	}
}

// waitForGrabReportActive polls display's grab report until Active >= n or
// timeout.
func waitForGrabReportActive(display string, n int, timeout time.Duration) bool {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if report, ok := proc.ReadGrabReport(display); ok && report.Active >= n {
			return true
		}
		time.Sleep(25 * time.Millisecond)
	}
	return false
}
