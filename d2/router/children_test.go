package main

// TestHelperProcess is the fake d2 child. It is invoked via os.Executable() when
// D2_ROUTER_TEST_HELPER=1 is set. It parses --port from argv and listens on
// 127.0.0.1:<port> as a minimal HTTP server. This avoids any real d2 binary.
//
// Build note: this file is compiled into the same test binary as the rest of the
// package. The helper is gated behind the D2_ROUTER_TEST_HELPER env variable so
// normal test runs never trigger it.

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

// TestMain gates the helper process entry point.
func TestMain(m *testing.M) {
	if os.Getenv("D2_ROUTER_TEST_HELPER") == "1" {
		runTestHelperProcess()
		// runTestHelperProcess exits; never returns.
	}
	os.Exit(m.Run())
}

// runTestHelperProcess is called when this binary is re-executed as the fake d2.
// It parses --port from argv and serves HTTP on 127.0.0.1:<port>.
// Behaviour by flag:
//   - default:            serve until SIGTERM, then exit 0
//   - --crash:            exit 3 immediately, BEFORE opening the port
//     (never becomes ready → exercises the readiness-failure path)
//   - --crash-after-ready: open the port, serve briefly, then exit 3
//     (becomes ready, then dies → exercises the crash-after-ready path
//     that records LastError in children.go)
func runTestHelperProcess() {
	args := os.Args[1:]
	port := ""
	crash := false
	crashAfterReady := false
	for i, a := range args {
		if a == "--port" && i+1 < len(args) {
			port = args[i+1]
		}
		if a == "--crash" {
			crash = true
		}
		if a == "--crash-after-ready" {
			crashAfterReady = true
		}
	}
	if port == "" {
		fmt.Fprintln(os.Stderr, "helper: --port not provided")
		os.Exit(1)
	}
	if crash {
		fmt.Fprintln(os.Stderr, "helper: crash requested (before listen)")
		os.Exit(3) // non-zero, never opens port → readiness-failure path
	}

	ln, err := net.Listen("tcp", "127.0.0.1:"+port)
	if err != nil {
		fmt.Fprintf(os.Stderr, "helper: listen on %s: %v\n", port, err)
		os.Exit(1)
	}

	if crashAfterReady {
		// Become ready (port is open), let the parent's readiness probe succeed,
		// then die non-zero to exercise the crash-after-ready path.
		fmt.Fprintln(os.Stderr, "helper: crash-after-ready requested")
		go func() {
			srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.WriteHeader(http.StatusOK)
			})}
			srv.Serve(ln) //nolint:errcheck — intentional: we exit below
		}()
		// Give the parent's readiness probe (100ms dial + 20ms poll) ample time
		// to connect and for Ensure to return before we exit.
		time.Sleep(200 * time.Millisecond)
		fmt.Fprintln(os.Stderr, "helper: crash-after-ready exiting")
		os.Exit(3) // non-zero, after becoming ready → crash path records LastError
	}

	srv := &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})}
	srv.Serve(ln) //nolint:errcheck — intentional: we exit on signal
	os.Exit(0)
}

// helperBin returns the path to this test binary — used as D2_ROUTER_D2_BIN.
// The binary is the currently-running executable (test binary reuses itself).
func helperBin(t *testing.T) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatalf("os.Executable: %v", err)
	}
	return exe
}

// helperEnv returns the env for re-execution as the test helper.
func helperEnv() []string {
	return append(os.Environ(), "D2_ROUTER_TEST_HELPER=1")
}

// makeHelperConfig builds a config where D2Bin points to this test binary.
// portBase is set to the given value so tests can control port allocation.
func makeHelperConfig(t *testing.T, portBase int) config {
	t.Helper()
	return config{
		D2Bin:         helperBin(t),
		ChildPortBase: strconv.Itoa(portBase),
		IdleTimeout:   "30m",
	}
}

// freePort returns a free TCP port for test use (by binding and immediately releasing).
func freePort(t *testing.T) int {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("freePort: %v", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port
	ln.Close()
	return port
}

// waitTCPOpen polls until 127.0.0.1:<port> accepts a connection or timeout.
func waitTCPOpen(t *testing.T, port int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		conn, err := net.DialTimeout("tcp", fmt.Sprintf("127.0.0.1:%d", port), 100*time.Millisecond)
		if err == nil {
			conn.Close()
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("port %d not open after %v", port, timeout)
}

// ── Tests ────────────────────────────────────────────────────────────────────

// TestEnsureSpawnsChildOnce: concurrent Ensure calls for the same key get the
// same process (one spawn), different keys get different processes.
func TestEnsureSpawnsChildOnce(t *testing.T) {
	cfg := makeHelperConfig(t, freePort(t))
	m := NewChildManager(cfg, helperEnv())
	defer m.StopAll()

	dir := t.TempDir()
	filePath := dir + "/test.d2"
	if err := os.WriteFile(filePath, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	key := "proj/test.d2"
	const concurrency = 10
	pids := make([]int, concurrency)
	errs := make([]error, concurrency)

	// Fan-out concurrent Ensure calls.
	done := make(chan int, concurrency)
	for i := 0; i < concurrency; i++ {
		go func(idx int) {
			ch, err := m.Ensure(key, filePath)
			if err != nil {
				errs[idx] = err
			} else {
				pids[idx] = ch.PID
			}
			done <- idx
		}(i)
	}
	for i := 0; i < concurrency; i++ {
		<-done
	}

	// Check no errors.
	for i, e := range errs {
		if e != nil {
			t.Errorf("goroutine %d: Ensure error: %v", i, e)
		}
	}

	// All should see the same pid.
	pid0 := pids[0]
	if pid0 == 0 {
		t.Fatal("Ensure returned zero pid")
	}
	for i, p := range pids {
		if p != pid0 {
			t.Errorf("goroutine %d pid %d != goroutine 0 pid %d (want same child)", i, p, pid0)
		}
	}
}

// TestEnsurePortAssignment: the manager skips a pre-occupied port.
func TestEnsurePortAssignment(t *testing.T) {
	// Pre-occupy a port so the manager must skip it.
	blocker, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	blockedPort := blocker.Addr().(*net.TCPAddr).Port
	defer blocker.Close()

	cfg := makeHelperConfig(t, blockedPort) // base = blocked port → must skip to next
	m := NewChildManager(cfg, helperEnv())
	defer m.StopAll()

	dir := t.TempDir()
	filePath := dir + "/probe.d2"
	if err := os.WriteFile(filePath, []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	ch, err := m.Ensure("proj/probe.d2", filePath)
	if err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	if ch.Port == blockedPort {
		t.Errorf("child assigned blocked port %d — should have skipped it", blockedPort)
	}
}

// TestRestart: Restart changes the PID and keeps the same key/port.
func TestRestart(t *testing.T) {
	cfg := makeHelperConfig(t, freePort(t))
	m := NewChildManager(cfg, helperEnv())
	defer m.StopAll()

	dir := t.TempDir()
	filePath := dir + "/restart.d2"
	if err := os.WriteFile(filePath, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	key := "proj/restart.d2"
	ch, err := m.Ensure(key, filePath)
	if err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	origPID := ch.PID
	origPort := ch.Port

	if err := m.Restart(key); err != nil {
		t.Fatalf("Restart: %v", err)
	}

	ch2, err := m.Ensure(key, filePath)
	if err != nil {
		t.Fatalf("Ensure after restart: %v", err)
	}

	if ch2.PID == origPID {
		t.Errorf("PID unchanged after restart: %d (want different pid)", ch2.PID)
	}
	if ch2.Port != origPort {
		t.Errorf("port changed from %d to %d (want same port)", origPort, ch2.Port)
	}
}

// TestReload: Reload touches the watched file (mtime updated).
func TestReload(t *testing.T) {
	cfg := makeHelperConfig(t, freePort(t))
	m := NewChildManager(cfg, helperEnv())
	defer m.StopAll()

	dir := t.TempDir()
	filePath := dir + "/reload.d2"
	if err := os.WriteFile(filePath, []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	key := "proj/reload.d2"
	if _, err := m.Ensure(key, filePath); err != nil {
		t.Fatalf("Ensure: %v", err)
	}

	// Record mtime before reload.
	info0, err := os.Stat(filePath)
	if err != nil {
		t.Fatal(err)
	}
	mtime0 := info0.ModTime()

	// Small sleep to ensure mtime changes detectably.
	time.Sleep(10 * time.Millisecond)

	if err := m.Reload(key); err != nil {
		t.Fatalf("Reload: %v", err)
	}

	info1, err := os.Stat(filePath)
	if err != nil {
		t.Fatal(err)
	}
	if !info1.ModTime().After(mtime0) {
		t.Errorf("mtime not updated after Reload: before=%v after=%v", mtime0, info1.ModTime())
	}
}

// TestStop: Stop removes the child from the map; subsequent Ensure spawns fresh.
func TestStop(t *testing.T) {
	cfg := makeHelperConfig(t, freePort(t))
	m := NewChildManager(cfg, helperEnv())
	defer m.StopAll()

	dir := t.TempDir()
	filePath := dir + "/stop.d2"
	if err := os.WriteFile(filePath, []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	key := "proj/stop.d2"
	ch1, err := m.Ensure(key, filePath)
	if err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	pid1 := ch1.PID

	if err := m.Stop(key); err != nil {
		t.Fatalf("Stop: %v", err)
	}

	// Re-ensure must spawn a fresh child.
	ch2, err := m.Ensure(key, filePath)
	if err != nil {
		t.Fatalf("Ensure after stop: %v", err)
	}
	if ch2.PID == pid1 {
		t.Errorf("after Stop+Ensure, got same PID %d — expected a new process", pid1)
	}
}

// TestDoubleStop: calling Stop twice on the same key must not panic or error fatally.
func TestDoubleStop(t *testing.T) {
	cfg := makeHelperConfig(t, freePort(t))
	m := NewChildManager(cfg, helperEnv())
	defer m.StopAll()

	dir := t.TempDir()
	filePath := dir + "/dstop.d2"
	if err := os.WriteFile(filePath, []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	key := "proj/dstop.d2"
	if _, err := m.Ensure(key, filePath); err != nil {
		t.Fatalf("Ensure: %v", err)
	}

	_ = m.Stop(key)
	// second Stop on a non-existent key should not panic
	err := m.Stop(key)
	// it may return an error (key not found) but must not panic
	_ = err
}

// TestCrashBeforeReady: a child that exits non-zero BEFORE opening its port never
// becomes ready, so Ensure returns an error (readiness-failure path) and the child
// is removed from the map. This path does NOT record LastError — the wait goroutine
// takes the deliberate-stop branch because spawnLocked calls stopCancel() on the
// readiness failure. See TestCrashAfterReadyRecordsLastError for the LastError path.
func TestCrashBeforeReady(t *testing.T) {
	cfg := makeHelperConfig(t, freePort(t))
	m := newCrashBeforeReadyManager(t, cfg)
	defer m.StopAll()

	dir := t.TempDir()
	filePath := dir + "/crash.d2"
	if err := os.WriteFile(filePath, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	key := "proj/crash.d2"
	// The child exits before opening its port, so probeReadyOrExit detects the
	// early exit and Ensure returns an error.
	_, ensureErr := m.Ensure(key, filePath)
	if ensureErr == nil {
		t.Error("expected Ensure to return an error for a child that crashes before ready, got nil")
	}

	// Give any background goroutines a moment to finish.
	time.Sleep(50 * time.Millisecond)

	// The child must not be in the map after the readiness failure.
	snapshot := m.Snapshot()
	if _, found := snapshot[key]; found {
		t.Error("crashed-before-ready child still in map — expected removal")
	}
}

// TestCrashAfterReadyRecordsLastError: a child that opens its port (becomes ready),
// then exits non-zero must (a) let Ensure succeed, and (b) have its LastError
// populated by the wait goroutine before the entry is removed from the map.
//
// This is the test that guards children.go's crash path (the `LastError = waitErr`
// assignment). Deleting that assignment must make this test fail.
//
// Race-free observation: Ensure returns the *Child the wait goroutine mutates.
// The goroutine writes LastError under e.mu, releases it, THEN takes m.mu to delete
// the map entry. So once Snapshot() (which takes m.mu) can no longer find the key,
// the delete — sequenced AFTER the LastError write in the goroutine's program order
// — has happened, and the m.mu release/acquire establishes happens-before. Reading
// ch.LastError after confirming removal is therefore data-race-free and guaranteed
// to observe the write.
func TestCrashAfterReadyRecordsLastError(t *testing.T) {
	cfg := makeHelperConfig(t, freePort(t))
	m := newCrashAfterReadyManager(t, cfg)
	defer m.StopAll()

	dir := t.TempDir()
	filePath := dir + "/crash-after-ready.d2"
	if err := os.WriteFile(filePath, []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}

	key := "proj/crash-after-ready.d2"
	// The child opens its port and becomes ready, so Ensure must succeed.
	ch, ensureErr := m.Ensure(key, filePath)
	if ensureErr != nil {
		t.Fatalf("expected Ensure to succeed for a child that crashes after becoming ready, got: %v", ensureErr)
	}
	if ch == nil {
		t.Fatal("Ensure returned nil child")
	}

	// Wait (race-free) for the wait goroutine to remove the crashed child from the
	// map. Removal is sequenced after the LastError write, so once removal is
	// observed the write is guaranteed visible.
	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, found := m.Snapshot()[key]; !found {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("crashed-after-ready child still in map after 5s — wait goroutine did not remove it")
		}
		time.Sleep(5 * time.Millisecond)
	}

	// (a) LastError must be populated by the crash path.
	if ch.LastError == nil {
		t.Error("LastError is nil after a crash-after-ready exit — expected the wait goroutine to record it")
	}

	// (b) The child must be removed from the map (confirmed by the loop above).
	if _, found := m.Snapshot()[key]; found {
		t.Error("crashed-after-ready child still in map — expected removal")
	}
}

// TestReaperKillsIdleChild: a child with clients==0 older than idle timeout is killed.
func TestReaperKillsIdleChild(t *testing.T) {
	cfg := makeHelperConfig(t, freePort(t))
	// Use a very short idle timeout for the reaper test.
	cfg.IdleTimeout = "100ms"
	m := NewChildManager(cfg, helperEnv())

	dir := t.TempDir()
	filePath := dir + "/reap.d2"
	if err := os.WriteFile(filePath, []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	key := "proj/reap.d2"
	ch, err := m.Ensure(key, filePath)
	if err != nil {
		t.Fatalf("Ensure: %v", err)
	}
	pid := ch.PID

	// Ensure client count is 0 (default) and last active is "now - more than idle".
	// Force lastActive to be old enough.
	m.ForceLastActive(key, time.Now().Add(-200*time.Millisecond))

	// Run one reaper cycle.
	m.Reap()

	// Wait for the child to die.
	time.Sleep(300 * time.Millisecond)

	// The child should be gone from the map.
	snapshot := m.Snapshot()
	if _, found := snapshot[key]; found {
		t.Errorf("child pid %d still in map after reaper — expected removal", pid)
	}
}

// TestPortRangeExhausted: when no ports are free in range, Ensure returns an error.
func TestPortRangeExhausted(t *testing.T) {
	// Use a tiny port range that is fully occupied.
	// We pick 2 consecutive ports and block both.
	p1 := freePort(t)
	ln1, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p1))
	if err != nil {
		t.Skip("could not bind test port")
	}
	defer ln1.Close()

	p2 := p1 + 1
	ln2, err := net.Listen("tcp", fmt.Sprintf("127.0.0.1:%d", p2))
	if err != nil {
		t.Skip("could not bind test port+1")
	}
	defer ln2.Close()

	cfg := makeHelperConfig(t, p1)
	cfg.ChildPortBase = strconv.Itoa(p1)
	// Limit range to 2 ports by setting PortRangeSize to 2 (if supported),
	// or rely on the implementation scanning a fixed window.
	m := NewChildManagerWithPortRange(cfg, helperEnv(), p1, p1+1) // inclusive [p1, p1+1]
	defer m.StopAll()

	dir := t.TempDir()
	filePath := dir + "/exhaust.d2"
	if err := os.WriteFile(filePath, []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	_, err = m.Ensure("proj/exhaust.d2", filePath)
	if err == nil {
		t.Error("expected error when port range exhausted, got nil")
	}
}

// TestClientCount: AddClient / RemoveClient are reflected in child state.
func TestClientCount(t *testing.T) {
	cfg := makeHelperConfig(t, freePort(t))
	m := NewChildManager(cfg, helperEnv())
	defer m.StopAll()

	dir := t.TempDir()
	filePath := dir + "/clients.d2"
	if err := os.WriteFile(filePath, []byte("a -> b"), 0644); err != nil {
		t.Fatal(err)
	}

	key := "proj/clients.d2"
	if _, err := m.Ensure(key, filePath); err != nil {
		t.Fatalf("Ensure: %v", err)
	}

	m.AddClient(key)
	m.AddClient(key)
	snap := m.Snapshot()
	if c := snap[key].Clients; c != 2 {
		t.Errorf("clients after 2 AddClient: got %d, want 2", c)
	}

	m.RemoveClient(key)
	snap = m.Snapshot()
	if c := snap[key].Clients; c != 1 {
		t.Errorf("clients after 1 RemoveClient: got %d, want 1", c)
	}
}

// TestStopAllNoZombies: StopAll kills every running child; no orphan processes.
func TestStopAllNoZombies(t *testing.T) {
	cfg := makeHelperConfig(t, freePort(t))
	m := NewChildManager(cfg, helperEnv())

	dir := t.TempDir()
	keys := []string{"proj/a.d2", "proj/b.d2"}
	pids := make([]int, len(keys))

	for i, key := range keys {
		fp := fmt.Sprintf("%s/%s", dir, fmt.Sprintf("%d.d2", i))
		if err := os.WriteFile(fp, []byte("a -> b"), 0644); err != nil {
			t.Fatal(err)
		}
		ch, err := m.Ensure(key, fp)
		if err != nil {
			t.Fatalf("Ensure %s: %v", key, err)
		}
		pids[i] = ch.PID
	}

	m.StopAll()

	// After StopAll, all children must have exited — sending signal 0 to the pid
	// should fail (process not found). Give them a moment to die.
	time.Sleep(300 * time.Millisecond)
	for i, pid := range pids {
		proc, err := os.FindProcess(pid)
		if err != nil {
			continue // not found — good
		}
		if err := proc.Signal(os.Signal(syscall.Signal(0))); err == nil {
			t.Errorf("child %d (pid %d) still alive after StopAll", i, pid)
		}
	}
}

// ── Crash helper ─────────────────────────────────────────────────────────────

// crashChildManager embeds ChildManager but injects a crash flag into spawn args.
type crashChildManager struct {
	*ChildManager
}

// newCrashBeforeReadyManager creates a ChildManager whose spawned children exit
// non-zero BEFORE opening their port — they never become ready. This exercises
// the readiness-failure path (probeReadyOrExit detects the early exit).
func newCrashBeforeReadyManager(t *testing.T, cfg config) *crashChildManager {
	t.Helper()
	m := NewChildManager(cfg, helperEnv())
	m.extraSpawnArgs = []string{"--crash"} // triggers exit(3) before net.Listen
	return &crashChildManager{m}
}

// newCrashAfterReadyManager creates a ChildManager whose spawned children open
// their port (become ready), then exit non-zero. This exercises the crash path
// in children.go that records LastError and removes the child from the map.
func newCrashAfterReadyManager(t *testing.T, cfg config) *crashChildManager {
	t.Helper()
	m := NewChildManager(cfg, helperEnv())
	m.extraSpawnArgs = []string{"--crash-after-ready"} // ready, then exit(3)
	return &crashChildManager{m}
}

// ChildManager exposes these for test-internal use (defined in children.go):
//   - ForceLastActive(key, t) — back-date lastActive
//   - Reap() — run one reaper cycle synchronously
//   - Snapshot() — return a copy of the current children map
//   - AddClient(key) / RemoveClient(key)

// Silence unused-import warnings for packages used only indirectly.
var (
	_ = atomic.Int32{}   // sync/atomic — used in concurrent tests
	_ = exec.Command     // os/exec — used via helperBin
	_ = context.Background // context — used in StartReaper
)
