package main

import (
	"context"
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"syscall"
	"time"
)

// childPortRangeDefault is the number of ports to scan before giving up.
const childPortRangeDefault = 200

// Child represents a running d2 --watch process managed by ChildManager.
// Fields are safe to read after Ensure returns; mutation is via the manager methods.
type Child struct {
	Key        string    // "{project}/{file}"
	AbsPath    string    // absolute path to the watched .d2 file
	Port       int       // TCP port the child listens on
	PID        int       // process ID of the child
	Clients    int32     // active WebSocket clients (proxy increments/decrements)
	LastActive time.Time // updated by AddClient, RemoveClient, and spawn
	LastError  error     // set by the Wait goroutine on crash
}

// childEntry is the internal mutable entry in the manager's map.
// mu is the per-key lock: held during spawn / restart operations.
// done is closed when the child process exits (used for readiness abort + Stop wait).
type childEntry struct {
	mu    sync.Mutex
	child *Child
	cmd   *exec.Cmd
	done  chan struct{} // closed when cmd.Wait() returns
	stop  context.CancelFunc // cancels crash-cleanup goroutine on deliberate stop
}

// ChildManager owns the lifecycle of all d2 child processes.
// It is safe for concurrent use from multiple goroutines (proxy, API, reaper).
type ChildManager struct {
	mu sync.RWMutex // guards the entries map

	cfg            config
	env            []string // os.Environ() for spawned processes (test seam)
	extraSpawnArgs []string // injected extra args for testing (e.g. --crash)

	portBase  int
	portLimit int // inclusive upper bound

	entries map[string]*childEntry
}

// NewChildManager creates a new ChildManager from the given config.
// env is the environment for spawned child processes (pass os.Environ() in production).
func NewChildManager(cfg config, env []string) *ChildManager {
	base, err := strconv.Atoi(cfg.ChildPortBase)
	if err != nil || base < 1 {
		base = 4801
	}
	return &ChildManager{
		cfg:       cfg,
		env:       env,
		portBase:  base,
		portLimit: base + childPortRangeDefault - 1,
		entries:   make(map[string]*childEntry),
	}
}

// NewChildManagerWithPortRange creates a ChildManager with a fixed [portLow, portHigh] range.
// Used by tests to provoke port-range exhaustion.
func NewChildManagerWithPortRange(cfg config, env []string, portLow, portHigh int) *ChildManager {
	m := NewChildManager(cfg, env)
	m.portBase = portLow
	m.portLimit = portHigh
	return m
}

// ── Public API ────────────────────────────────────────────────────────────────

// Ensure returns the running Child for key, spawning one if needed.
// Concurrent callers for the same key share the child (per-key lock inside).
// Readiness is verified by a TCP probe before returning.
// Returns an error if the child fails to start or the port never opens.
func (m *ChildManager) Ensure(key, absPath string) (*Child, error) {
	// Fast path: child already running.
	m.mu.RLock()
	e, ok := m.entries[key]
	m.mu.RUnlock()
	if ok {
		e.mu.Lock()
		ch := e.child
		e.mu.Unlock()
		if ch != nil && ch.PID != 0 {
			return ch, nil
		}
	}

	// Slow path: need to spawn. Acquire global write lock to insert/find entry,
	// then per-key lock to serialize concurrent Ensure calls for the same key.
	m.mu.Lock()
	e, ok = m.entries[key]
	if !ok {
		e = &childEntry{}
		m.entries[key] = e
	}
	m.mu.Unlock()

	e.mu.Lock()
	defer e.mu.Unlock()

	// Double-check after acquiring the per-key lock (another goroutine may have spawned).
	if e.child != nil && e.child.PID != 0 {
		return e.child, nil
	}

	ch, err := m.spawnLocked(e, key, absPath, 0)
	if err != nil {
		// Clean up the placeholder entry we inserted into the map.
		m.mu.Lock()
		if current, ok := m.entries[key]; ok && current == e {
			delete(m.entries, key)
		}
		m.mu.Unlock()
		return nil, err
	}
	return ch, nil
}

// spawnLocked spawns a new child process for the given key/absPath.
// If port != 0 it is used directly (for Restart); otherwise a free port is found.
// Must be called with e.mu held.
func (m *ChildManager) spawnLocked(e *childEntry, key, absPath string, port int) (*Child, error) {
	var err error
	if port == 0 {
		port, err = m.findFreePort()
		if err != nil {
			return nil, fmt.Errorf("ensure %q: %w", key, err)
		}
	}

	args := []string{
		"--watch",
		"--browser", "0",
		"--host", "127.0.0.1",
		"--port", strconv.Itoa(port),
		absPath,
	}
	args = append(args, m.extraSpawnArgs...)

	cmd := exec.Command(m.cfg.D2Bin, args...) //nolint:gosec — D2Bin is admin-configured
	cmd.Env = m.env

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("ensure %q: spawn %s: %w", key, m.cfg.D2Bin, err)
	}

	ch := &Child{
		Key:        key,
		AbsPath:    absPath,
		Port:       port,
		PID:        cmd.Process.Pid,
		LastActive: time.Now(),
	}

	done := make(chan struct{})
	stopCtx, stopCancel := context.WithCancel(context.Background())

	e.child = ch
	e.cmd = cmd
	e.done = done
	e.stop = stopCancel

	// Single wait goroutine: owns cmd.Wait() and closes done when process exits.
	// Also handles crash cleanup unless the stop context was cancelled first.
	go func() {
		waitErr := cmd.Wait()
		close(done)

		select {
		case <-stopCtx.Done():
			// Deliberate stop/restart — crash cleanup suppressed.
			return
		default:
		}

		// Crash: record error and remove from map.
		e.mu.Lock()
		if e.child != nil {
			e.child.LastError = waitErr
			log.Printf("children: %q crashed: %v", key, waitErr)
		}
		e.mu.Unlock()

		m.mu.Lock()
		// Only remove if the map entry still points to this same entry.
		if current, ok := m.entries[key]; ok && current == e {
			delete(m.entries, key)
		}
		m.mu.Unlock()
	}()

	// Probe readiness: TCP connect with deadline, abort early if child exits.
	if err := probeReadyOrExit(port, done); err != nil {
		// Readiness failed — cancel crash-cleanup goroutine and clean up.
		stopCancel()
		// Kill the process (it may have already exited).
		_ = cmd.Process.Kill()
		// Wait for the wait goroutine to finish (it already called cmd.Wait).
		<-done

		m.mu.Lock()
		if current, ok := m.entries[key]; ok && current == e {
			delete(m.entries, key)
		}
		m.mu.Unlock()
		e.child = nil
		return nil, fmt.Errorf("ensure %q: readiness failed on port %d: %w", key, port, err)
	}

	log.Printf("children: spawned %q pid=%d port=%d", key, cmd.Process.Pid, port)
	return ch, nil
}

// Reload touches the watched file via os.Chtimes to trigger d2 recompile.
// Returns an error if the key is not running.
func (m *ChildManager) Reload(key string) error {
	m.mu.RLock()
	e, ok := m.entries[key]
	m.mu.RUnlock()
	if !ok {
		return fmt.Errorf("reload %q: not running", key)
	}

	e.mu.Lock()
	absPath := ""
	if e.child != nil {
		absPath = e.child.AbsPath
	}
	e.mu.Unlock()

	if absPath == "" {
		return fmt.Errorf("reload %q: no abs path", key)
	}

	now := time.Now()
	if err := os.Chtimes(absPath, now, now); err != nil {
		return fmt.Errorf("reload %q: chtimes: %w", key, err)
	}
	return nil
}

// Restart terminates the current child via SIGTERM → 2s → SIGKILL, then
// respawns a new process with the same key and absPath.
// The same port is reused for the new child.
// Returns an error if the key is not running or respawn fails.
func (m *ChildManager) Restart(key string) error {
	m.mu.RLock()
	e, ok := m.entries[key]
	m.mu.RUnlock()
	if !ok {
		return fmt.Errorf("restart %q: not running", key)
	}

	e.mu.Lock()
	defer e.mu.Unlock()

	if e.child == nil {
		return fmt.Errorf("restart %q: no child state", key)
	}
	absPath := e.child.AbsPath
	oldPort := e.child.Port

	// Suppress crash-cleanup goroutine for the deliberate kill.
	if e.stop != nil {
		e.stop()
	}
	killAndWait(e.cmd, e.done)

	// Clear old state; respawn on the same port.
	e.child = nil
	e.cmd = nil
	e.done = nil
	e.stop = nil

	ch, err := m.spawnLocked(e, key, absPath, oldPort)
	if err != nil {
		// Remove the map entry so a future Ensure can try again.
		m.mu.Lock()
		if current, ok2 := m.entries[key]; ok2 && current == e {
			delete(m.entries, key)
		}
		m.mu.Unlock()
		return fmt.Errorf("restart %q: %w", key, err)
	}
	_ = ch
	return nil
}

// Stop terminates the child for key and removes it from the map.
// Returns an error if the key is not found; double-stop is safe.
func (m *ChildManager) Stop(key string) error {
	m.mu.Lock()
	e, ok := m.entries[key]
	if ok {
		delete(m.entries, key)
	}
	m.mu.Unlock()

	if !ok {
		return fmt.Errorf("stop %q: not running", key)
	}

	e.mu.Lock()
	defer e.mu.Unlock()

	if e.stop != nil {
		e.stop() // suppress crash-cleanup goroutine
	}
	killAndWait(e.cmd, e.done)
	log.Printf("children: stopped %q", key)
	return nil
}

// StopAll terminates every running child. Used on daemon shutdown.
// Blocks until all children have exited (no zombies).
func (m *ChildManager) StopAll() {
	m.mu.Lock()
	entries := make(map[string]*childEntry, len(m.entries))
	for k, e := range m.entries {
		entries[k] = e
	}
	for k := range m.entries {
		delete(m.entries, k)
	}
	m.mu.Unlock()

	var wg sync.WaitGroup
	for key, e := range entries {
		wg.Add(1)
		go func(key string, e *childEntry) {
			defer wg.Done()
			e.mu.Lock()
			defer e.mu.Unlock()
			if e.stop != nil {
				e.stop()
			}
			killAndWait(e.cmd, e.done)
			log.Printf("children: shutdown: stopped %q", key)
		}(key, e)
	}
	wg.Wait()
}

// StartReaper starts the background idle-reaper goroutine.
// It runs until ctx is cancelled (typically on daemon shutdown).
func (m *ChildManager) StartReaper(ctx context.Context) {
	idleTimeout, err := time.ParseDuration(m.cfg.IdleTimeout)
	if err != nil || idleTimeout <= 0 {
		idleTimeout = 30 * time.Minute
	}
	interval := idleTimeout / 2
	if interval < time.Second {
		interval = time.Second
	}
	ticker := time.NewTicker(interval)
	go func() {
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				m.reapWithTimeout(idleTimeout)
			}
		}
	}()
}

// Reap runs one synchronous reaper cycle using the configured idle timeout.
// Exposed for tests.
func (m *ChildManager) Reap() {
	idleTimeout, err := time.ParseDuration(m.cfg.IdleTimeout)
	if err != nil || idleTimeout <= 0 {
		idleTimeout = 30 * time.Minute
	}
	m.reapWithTimeout(idleTimeout)
}

// reapWithTimeout kills children with clients==0 idle longer than idleTimeout.
func (m *ChildManager) reapWithTimeout(idleTimeout time.Duration) {
	now := time.Now()

	m.mu.RLock()
	keys := make([]string, 0, len(m.entries))
	for k := range m.entries {
		keys = append(keys, k)
	}
	m.mu.RUnlock()

	for _, key := range keys {
		m.mu.RLock()
		e, ok := m.entries[key]
		m.mu.RUnlock()
		if !ok {
			continue
		}

		e.mu.Lock()
		ch := e.child
		// A child whose source .d2 was deleted is reaped regardless of
		// clients or idleness (dotfiles-t1o delete-side): the idle-only rule
		// left it — and its port — alive for as long as a browser held the
		// /watch socket open, which is the live-preview socket after adr0009.
		// os.Stat under e.mu is a fast local syscall; ErrNotExist is the only
		// signal that counts (a transient stat error is not a deletion).
		gone := ch != nil && func() bool {
			_, err := os.Stat(ch.AbsPath)
			return errors.Is(err, os.ErrNotExist)
		}()
		idle := ch != nil && ch.Clients == 0 && now.Sub(ch.LastActive) > idleTimeout
		shouldReap := gone || idle
		e.mu.Unlock()

		if shouldReap {
			reason := "idle"
			if gone {
				reason = "source file deleted"
			}
			log.Printf("children: reaper: %q %s — stopping", key, reason)
			_ = m.Stop(key)
		}
	}
}

// AddClient increments the client counter for key and updates LastActive.
func (m *ChildManager) AddClient(key string) {
	m.mu.RLock()
	e, ok := m.entries[key]
	m.mu.RUnlock()
	if !ok {
		return
	}
	e.mu.Lock()
	if e.child != nil {
		e.child.Clients++
		e.child.LastActive = time.Now()
	}
	e.mu.Unlock()
}

// RemoveClient decrements the client counter for key and updates LastActive.
func (m *ChildManager) RemoveClient(key string) {
	m.mu.RLock()
	e, ok := m.entries[key]
	m.mu.RUnlock()
	if !ok {
		return
	}
	e.mu.Lock()
	if e.child != nil && e.child.Clients > 0 {
		e.child.Clients--
		e.child.LastActive = time.Now()
	}
	e.mu.Unlock()
}

// ForceLastActive back-dates a child's LastActive for testing the reaper.
func (m *ChildManager) ForceLastActive(key string, t time.Time) {
	m.mu.RLock()
	e, ok := m.entries[key]
	m.mu.RUnlock()
	if !ok {
		return
	}
	e.mu.Lock()
	if e.child != nil {
		e.child.LastActive = t
	}
	e.mu.Unlock()
}

// Snapshot returns a shallow copy of the current child state map (key → Child copy).
// Safe for concurrent use; the returned map is a snapshot — not live.
func (m *ChildManager) Snapshot() map[string]Child {
	m.mu.RLock()
	defer m.mu.RUnlock()

	snap := make(map[string]Child, len(m.entries))
	for k, e := range m.entries {
		e.mu.Lock()
		if e.child != nil {
			snap[k] = *e.child
		}
		e.mu.Unlock()
	}
	return snap
}

// ── Internal helpers ──────────────────────────────────────────────────────────

// findFreePort probes ports from portBase to portLimit and returns the first free one.
// A port is "free" if no TCP listener is bound to it on 127.0.0.1.
func (m *ChildManager) findFreePort() (int, error) {
	for p := m.portBase; p <= m.portLimit; p++ {
		if !isPortOccupied(p) {
			return p, nil
		}
	}
	return 0, fmt.Errorf("port range %d–%d exhausted", m.portBase, m.portLimit)
}

// isPortOccupied returns true if 127.0.0.1:<port> is already bound.
func isPortOccupied(port int) bool {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return true // bind failed → occupied
	}
	ln.Close()
	return false
}

// probeReadyOrExit polls 127.0.0.1:<port> until it accepts a TCP connection,
// or the child exits early (done closed). Timeout is 10 seconds.
func probeReadyOrExit(port int, done <-chan struct{}) error {
	addr := fmt.Sprintf("127.0.0.1:%d", port)
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-done:
			return fmt.Errorf("child exited before port %d was ready", port)
		default:
		}
		conn, err := net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			conn.Close()
			return nil
		}
		time.Sleep(20 * time.Millisecond)
	}
	return fmt.Errorf("port %d not ready after 10s", port)
}

// killAndWait sends SIGTERM to cmd, waits up to 2 s, then SIGKILL.
// done is the channel closed by the wait goroutine when cmd.Wait() returns.
// If cmd or done is nil, this is a no-op.
func killAndWait(cmd *exec.Cmd, done <-chan struct{}) {
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGTERM)
	if done == nil {
		_ = cmd.Process.Kill()
		return
	}
	select {
	case <-done:
		return
	case <-time.After(2 * time.Second):
		_ = cmd.Process.Kill()
		<-done
	}
}
