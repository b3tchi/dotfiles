//go:build windows

package main

// sp012 Task 7 (kwi3-hoex.7) on real Windows, through hotkeyd/test-win32.sh
// (the "_Windows_" name is its filter): --health against a real dry-run
// daemon with each check failing in turn, and `hotkeyd recover` against a
// real daemon process - this test binary run as hotkeyd (TestMain).
//
// SAFETY. Every daemon here is a DRY RUN (HOTKEYD_WIN32_DRYRUN=1): nothing
// is registered with Windows, whose registrations are window-station wide.
// Every recover runs dry too, so it reads GetAsyncKeyState but never calls
// SendInput (that would reach the input desktop - Jan's). %LOCALAPPDATA% is
// a private directory per test, so the lock, sockets, args record and log
// never touch the real %LOCALAPPDATA%\hotkeyd; $KWI3SOCK is a pipe this
// test serves (or one nobody serves) - never the host's own. The only
// processes ended are this test's own daemons, by the pid in their lock
// and only while that lock is held.

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
	"unsafe"

	"hotkeyd/internal/bind"
	"hotkeyd/internal/proc"
	"hotkeyd/internal/win32"
)

// asHotkeydEnv makes this test binary BE hotkeyd: TestMain hands its
// arguments to Dispatch, so `<test.exe> --input win32` is the daemon and
// `<test.exe> recover` is recover, and recover's os.Executable() restart
// starts the same binary again.
const asHotkeydEnv = "HOTKEYD_TEST_AS_HOTKEYD"

// compiledTableEnv, set to 1 beside asHotkeydEnv, keeps the COMPILED table
// (the -tags win32 one under GOFLAGS=-tags=win32) instead of smallTable.
const compiledTableEnv = "HOTKEYD_TEST_COMPILED_TABLE"

// sendInputStubMark is what the stubbed key-up prints: a test that finds it
// in recover's output caught a key-up that a dry run should never reach.
const sendInputStubMark = "TEST: SendInput stub called"

func TestMain(m *testing.M) {
	if dir := os.Getenv(asKwi3RunEnv); dir != "" {
		// A copy of this binary deployed as kwi3-run.exe
		// (TestKwi3Run_Windows_Deployed): say which
		// image ran with which verb, and exit.
		exe, _ := os.Executable()
		_ = os.WriteFile(filepath.Join(dir, "kwi3-run-ran.txt"),
			[]byte(exe+"\n"+strings.Join(os.Args[1:], " ")), 0o644)
		os.Exit(0)
	}
	if os.Getenv(asHotkeydEnv) == "1" {
		// Never real input from a test binary, dry run or not.
		recoverKeyUp = func(vk uint16) error {
			fmt.Fprintf(os.Stderr, "%s for vk 0x%02x\n", sendInputStubMark, vk)
			return errors.New("SendInput is stubbed in a test binary")
		}
		// smallTable, not the compiled one, unless a test asks for it:
		// most of these tests are about recover, not the table, and the
		// compiled table would spawn its overlay from the restarted
		// daemon. (Its hook-served chords count as granted:
		// TestHealth_Windows_HookTable, sp012 Task 5, and recover on it
		// is TestRecover_Windows_CompiledTableAndHook_ExitsZero.)
		if os.Getenv(compiledTableEnv) != "1" {
			Binds, Layers = smallTable, map[string]bind.Layer{}
		}
		os.Exit(Dispatch(os.Args[1:]))
	}
	os.Exit(m.Run())
}

// -- a named-pipe kwi3 stand-in ----------------------------------------------

var (
	k32Test                 = syscall.NewLazyDLL("kernel32.dll")
	procCreateNamedPipeW    = k32Test.NewProc("CreateNamedPipeW")
	procConnectNamedPipe    = k32Test.NewProc("ConnectNamedPipe")
	procDisconnectNamedPipe = k32Test.NewProc("DisconnectNamedPipe")
	pipeSeq                 int64
)

func testPipeName() string {
	return fmt.Sprintf(`\\.\pipe\hotkeyd-recover-test-%d-%d`, os.Getpid(), atomic.AddInt64(&pipeSeq, 1))
}

// kwi3Pipe answers every JSON-RPC line with an empty result, on as many
// instances as are dialled.
type kwi3Pipe struct {
	name    string
	stopped atomic.Bool
	done    chan struct{}
}

func serveKwi3Pipe(t *testing.T, name string) *kwi3Pipe {
	t.Helper()
	p := &kwi3Pipe{name: name, done: make(chan struct{})}
	h, err := p.create()
	if err != nil {
		t.Fatalf("CreateNamedPipe %s: %v", name, err)
	}
	go p.listen(h)
	t.Cleanup(p.stop)
	return p
}

func (p *kwi3Pipe) create() (syscall.Handle, error) {
	n, _ := syscall.UTF16PtrFromString(p.name)
	r, _, err := procCreateNamedPipeW.Call(uintptr(unsafe.Pointer(n)), 0x3, 0, 255, 65536, 65536, 0, 0)
	if syscall.Handle(r) == syscall.InvalidHandle {
		return syscall.InvalidHandle, err
	}
	return syscall.Handle(r), nil
}

func (p *kwi3Pipe) listen(h syscall.Handle) {
	defer close(p.done)
	for {
		r, _, err := procConnectNamedPipe.Call(uintptr(h), 0)
		if r == 0 && !errors.Is(err, syscall.Errno(535)) { // ERROR_PIPE_CONNECTED
			syscall.CloseHandle(h)
			return
		}
		if p.stopped.Load() {
			procDisconnectNamedPipe.Call(uintptr(h))
			syscall.CloseHandle(h)
			return
		}
		go serveRPC(h)
		nh, err := p.create()
		if err != nil {
			return
		}
		h = nh
	}
}

func serveRPC(h syscall.Handle) {
	defer func() {
		procDisconnectNamedPipe.Call(uintptr(h))
		syscall.CloseHandle(h)
	}()
	r := bufio.NewReader(pipeRW(h))
	for {
		line, err := r.ReadBytes('\n')
		if err != nil {
			return
		}
		var req struct {
			ID int64 `json:"id"`
		}
		if json.Unmarshal(line, &req) != nil {
			continue
		}
		out, _ := json.Marshal(map[string]interface{}{"jsonrpc": "2.0", "id": req.ID, "result": []interface{}{}})
		if _, err := pipeRW(h).Write(append(out, '\n')); err != nil {
			return
		}
	}
}

// stop: no new instance; the one parked in ConnectNamedPipe is woken by a
// throwaway client. Connected instances are left to their clients.
func (p *kwi3Pipe) stop() {
	if p.stopped.Swap(true) {
		return
	}
	n, _ := syscall.UTF16PtrFromString(p.name)
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		select {
		case <-p.done:
			return
		default:
		}
		if h, err := syscall.CreateFile(n, syscall.GENERIC_READ|syscall.GENERIC_WRITE, 0, nil, syscall.OPEN_EXISTING, 0, 0); err == nil {
			syscall.CloseHandle(h)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

type pipeRW syscall.Handle

func (h pipeRW) Read(b []byte) (int, error) {
	var n uint32
	err := syscall.ReadFile(syscall.Handle(h), b, &n, nil)
	if err == nil && n == 0 {
		return 0, errors.New("EOF")
	}
	return int(n), err
}

func (h pipeRW) Write(b []byte) (int, error) {
	var n uint32
	err := syscall.WriteFile(syscall.Handle(h), b, &n, nil)
	return int(n), err
}

// privateLocalAppData points %LOCALAPPDATA% at a fresh directory for this
// test (and for every process it starts, which inherit the environment).
// Not t.TempDir(): an AF_UNIX path must stay under 108 bytes.
func privateLocalAppData(t *testing.T) string {
	t.Helper()
	base, err := os.MkdirTemp("", "hk")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for i := 0; i < 50; i++ {
			if os.RemoveAll(base) == nil {
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
	})
	t.Setenv("LOCALAPPDATA", base)
	return base
}

// -- --health on Windows, each check failing in turn ---------------------------

func TestHealth_Windows_EachCheckFailingInTurn(t *testing.T) {
	privateLocalAppData(t)
	desk := fmt.Sprintf("kwi3t-hk-%d", os.Getpid())
	expect := func(step string, code int, names string) {
		t.Helper()
		got, msg := runHealth(desk)
		t.Logf("%s: %d %s", step, got, msg)
		if got != code || !strings.Contains(msg, names) {
			t.Fatalf("%s: --health = %d %q, want %d naming %q", step, got, msg, code, names)
		}
	}

	// 1. No lock at all.
	expect("no lock", HealthNotServing, "lock:")

	// 2. A lock naming a pid that has exited.
	dead := exec.Command(os.Getenv("ComSpec"), "/c", "exit 0")
	if err := dead.Run(); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(proc.RuntimeDir(), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(proc.LockPath(desk), []byte(fmt.Sprintf("%d\n%s\n", dead.ProcessState.Pid(), proc.LockMarker)), 0o644); err != nil {
		t.Fatal(err)
	}
	expect("lock pid dead", HealthNotServing, fmt.Sprintf("lock: pid %d", dead.ProcessState.Pid()))

	// 3. The lock held by a live pid (this one) with no control socket.
	lock, err := proc.AcquireLock(proc.LockPath(desk))
	if err != nil {
		t.Fatal(err)
	}
	defer lock.Release()
	expect("no control socket", HealthNotServing, "control:")

	// 4. A daemon whose RegisterHotKey refused one chord: Alt+2.
	pipe := testPipeName()
	srv := serveKwi3Pipe(t, pipe)
	refuse := func(_ uintptr, _ int32, _ uint32, vk uint16) error {
		if vk == '2' {
			return win32.ERROR_HOTKEY_ALREADY_REGISTERED
		}
		return nil
	}
	dae, _, err := startWin32(win32Config{
		Display:  desk,
		Kwi3Sock: pipe,
		Binds:    smallTable,
		Layers:   map[string]bind.Layer{},
		Source:   win32.Options{Register: refuse},
		Log:      func(s string) { t.Log(s) },
	})
	if err != nil {
		t.Fatalf("startWin32: %v", err)
	}
	sig := make(chan os.Signal, 1)
	done := make(chan int, 1)
	go func() { done <- dae.Run(sig) }()
	expect("a chord refused", HealthDegraded, "chords: 1 of 2")
	sig <- os.Interrupt
	<-done

	// 5. Every chord granted, kwi3 answering: serving.
	dae, _, err = startWin32(win32Config{
		Display:  desk,
		Kwi3Sock: pipe,
		Binds:    smallTable,
		Layers:   map[string]bind.Layer{},
		Source:   win32.Options{DryRun: true},
		Log:      func(s string) { t.Log(s) },
	})
	if err != nil {
		t.Fatalf("startWin32: %v", err)
	}
	sig = make(chan os.Signal, 1)
	done = make(chan int, 1)
	go func() { done <- dae.Run(sig) }()
	defer func() { sig <- os.Interrupt; <-done }()
	expect("serving", HealthOK, "serving")

	// 6. kwi3 gone: the kwi3rpc connection is down.
	srv.stop()
	expect("kwi3 gone", HealthNotServing, "kwi3rpc:")
}

// -- recover against a real daemon process -------------------------------------

// hotkeydEnv is the environment of a daemon or recover run of this binary.
func hotkeydEnv(kwi3Sock string) []string {
	return append(os.Environ(),
		asHotkeydEnv+"=1",
		win32DryRunEnvName+"=1",
		"KWI3SOCK="+kwi3Sock,
	)
}

// selfExe is this test binary's absolute path.
func selfExe(t *testing.T) string {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	return exe
}

// startHotkeydProcess starts this binary as `hotkeyd --input win32`.
func startHotkeydProcess(t *testing.T, kwi3Sock string) *exec.Cmd {
	t.Helper()
	cmd := exec.Command(selfExe(t), "--input", "win32")
	cmd.Env = hotkeydEnv(kwi3Sock)
	if err := cmd.Start(); err != nil {
		t.Fatalf("start hotkeyd: %v", err)
	}
	return cmd
}

// stopOwnDaemon ends the daemon this test's run left behind: the pid in
// the PRIVATE lock, only while that lock is held - a stop on its control
// socket, then the handle opened on that pid.
func stopOwnDaemon(t *testing.T) {
	desk := resolveDisplay("")
	lp := proc.LockPath(desk)
	pid, ok := proc.LockPID(lp)
	if !ok || !proc.LockHeld(lp) {
		return
	}
	p, err := openWinProc(pid)
	if err != nil {
		t.Errorf("cleanup: cannot open the test's daemon pid %d: %v", pid, err)
		return
	}
	defer p.Close()
	_ = stopViaControl(proc.ControlPath(desk), recoverControlTimeout)
	if !p.Wait(5 * time.Second) {
		t.Errorf("cleanup: the test's daemon pid %d ignored stop; ending it by its handle", pid)
		_ = p.Terminate()
		p.Wait(5 * time.Second)
	}
}

func waitHealthy(t *testing.T, within time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(within)
	for {
		code, msg := runHealth("")
		if code == HealthOK {
			return msg
		}
		if time.Now().After(deadline) {
			t.Fatalf("daemon not serving within %s: %d %s", within, code, msg)
		}
		time.Sleep(100 * time.Millisecond)
	}
}

func runRecoverProcess(t *testing.T, kwi3Sock string) (int, string) {
	t.Helper()
	cmd := exec.Command(selfExe(t), "recover")
	cmd.Env = hotkeydEnv(kwi3Sock)
	out, err := cmd.CombinedOutput()
	code := 0
	if err != nil {
		var ee *exec.ExitError
		if !errors.As(err, &ee) {
			t.Fatalf("recover: %v", err)
		}
		code = ee.ExitCode()
	}
	return code, string(out)
}

func TestRecover_Windows_DaemonUp_RecoverChangesPidAndHealthIsGreen(t *testing.T) {
	privateLocalAppData(t)
	pipe := testPipeName()
	serveKwi3Pipe(t, pipe)
	t.Cleanup(func() { stopOwnDaemon(t) })

	old := startHotkeydProcess(t, pipe)
	oldDone := make(chan error, 1)
	go func() { oldDone <- old.Wait() }()
	t.Logf("before: %s", waitHealthy(t, 10*time.Second))
	lp := proc.LockPath(resolveDisplay(""))
	if pid, _ := proc.LockPID(lp); pid != old.Process.Pid {
		t.Fatalf("lock names pid %d, want the started daemon %d", pid, old.Process.Pid)
	}
	rec, ok := readArgsRecord(resolveDisplay(""))
	if !ok || strings.Join(rec.Args, " ") != "--input win32" || rec.Env["KWI3SOCK"] != pipe || rec.Env[win32DryRunEnvName] != "1" {
		t.Fatalf("args record = %+v, %v", rec, ok)
	}

	start := time.Now()
	code, out := runRecoverProcess(t, pipe)
	t.Logf("recover (%s) exit %d:\n%s", time.Since(start).Round(time.Millisecond), code, out)
	if code != 0 {
		t.Fatalf("recover = %d, want 0", code)
	}
	select {
	case err := <-oldDone:
		if err != nil {
			t.Fatalf("the old daemon exited with %v, want 0 on the control socket's stop", err)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("the old daemon is still running after recover")
	}
	if !strings.Contains(out, "stopped on the control socket's stop") || strings.Contains(out, "BY PID") {
		t.Fatalf("recover output does not show a clean control stop:\n%s", out)
	}
	newPID, _ := proc.LockPID(lp)
	if newPID == old.Process.Pid || newPID == 0 {
		t.Fatalf("lock pid %d after recover, want a new pid (old %d)", newPID, old.Process.Pid)
	}
	code2, msg := runHealth("")
	if code2 != HealthOK || !strings.Contains(msg, fmt.Sprintf("pid %d", newPID)) {
		t.Fatalf("--health after recover = %d %q, want serving from pid %d", code2, msg, newPID)
	}
	if !strings.Contains(out, "DRY RUN") && !strings.Contains(out, "no modifier held") {
		t.Fatalf("recover output says nothing about modifiers:\n%s", out)
	}
}

// recover against a daemon on the COMPILED table (the -tags win32 one under
// GOFLAGS=-tags=win32) with its low-level hook: exit 0 inside the 12 s
// budget, the new pid serving. Dry run throughout - no chord registered, no
// hook installed (startHook installs none on a dry run), SendInput stubbed
// (TestMain) - with PATH emptied so the table's overlay (kwi3-run.exe under
// -tags win32) can never start, a private %LOCALAPPDATA% and a stand-in
// kwi3 pipe.
func TestRecover_Windows_CompiledTableAndHook_ExitsZero(t *testing.T) {
	privateLocalAppData(t)
	pipe := testPipeName()
	serveKwi3Pipe(t, pipe)
	t.Cleanup(func() { stopOwnDaemon(t) })
	t.Logf("compiled table: %d binds, needs the hook: %v", len(effectiveBinds(pipe)), tableNeedsHook(effectiveBinds(pipe), Layers))
	if !tableNeedsHook(effectiveBinds(pipe), Layers) {
		t.Log("this build's table needs no hook (run with GOFLAGS=-tags=win32 for the Windows table)")
	}
	env := setEnv(append(hotkeydEnv(pipe), compiledTableEnv+"=1"), "PATH", t.TempDir())

	old := exec.Command(selfExe(t), "--input", "win32")
	old.Env = env
	if err := old.Start(); err != nil {
		t.Fatalf("start hotkeyd: %v", err)
	}
	oldDone := make(chan error, 1)
	go func() { oldDone <- old.Wait() }()
	t.Logf("before: %s", waitHealthy(t, 10*time.Second))

	cmd := exec.Command(selfExe(t), "recover")
	cmd.Env = env
	start := time.Now()
	outB, err := cmd.CombinedOutput()
	took := time.Since(start)
	out := string(outB)
	t.Logf("recover (%s) err %v:\n%s", took.Round(time.Millisecond), err, out)
	if err != nil {
		t.Fatalf("recover = %v, want exit 0", err)
	}
	if took > recoverBudget {
		t.Fatalf("recover took %s, want within the %s budget", took, recoverBudget)
	}
	if strings.Contains(out, sendInputStubMark) {
		t.Fatalf("a dry-run recover reached SendInput:\n%s", out)
	}
	select {
	case <-oldDone:
	case <-time.After(3 * time.Second):
		t.Fatal("the old daemon is still running after recover")
	}
	lp := proc.LockPath(resolveDisplay(""))
	newPID, _ := proc.LockPID(lp)
	if newPID == old.Process.Pid || newPID == 0 {
		t.Fatalf("lock pid %d after recover, want a new pid (old %d)", newPID, old.Process.Pid)
	}
	code, msg := runHealth("")
	if code != HealthOK || !strings.Contains(msg, fmt.Sprintf("pid %d", newPID)) {
		t.Fatalf("--health after recover = %d %q, want serving from pid %d", code, msg, newPID)
	}
}

func TestRecover_Windows_MissingPipe_ExitsOneNamingKwi3rpc(t *testing.T) {
	privateLocalAppData(t)
	pipe := testPipeName() // nobody serves it
	t.Cleanup(func() { stopOwnDaemon(t) })

	old := startHotkeydProcess(t, pipe)
	go func() { _ = old.Wait() }()
	// Up, but not serving: kwi3rpc is down.
	deadline := time.Now().Add(10 * time.Second)
	for {
		code, msg := runHealth("")
		if strings.Contains(msg, "kwi3rpc:") {
			if code != HealthNotServing {
				t.Fatalf("--health = %d %q, want 6", code, msg)
			}
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("the daemon never reached the kwi3rpc check: %d %s", code, msg)
		}
		time.Sleep(100 * time.Millisecond)
	}

	start := time.Now()
	code, out := runRecoverProcess(t, pipe)
	took := time.Since(start)
	t.Logf("recover (%s) exit %d:\n%s", took.Round(time.Millisecond), code, out)
	if code != 1 {
		t.Fatalf("recover = %d, want 1", code)
	}
	if !strings.Contains(out, "not serving within the 12s budget") || !strings.Contains(out, "kwi3rpc") {
		t.Fatalf("recover output does not name kwi3rpc:\n%s", out)
	}
	// The whole run is bounded by recoverBudget (12 s, kwi3-hoex.21), and
	// the host waits 15 s: recover must answer before the host gives up.
	if took < 11*time.Second || took > 14*time.Second {
		t.Fatalf("recover took %s, want just under 12s plus process start, never near the host's 15s", took)
	}
}

// The INPUT a key-up is sent in must be the size SendInput checks cbSize
// against (40 on amd64), or every call fails. Checked without calling it.
func TestSendKeyUp_Windows_InputIsFortyBytes(t *testing.T) {
	if n := unsafe.Sizeof(keybdInput{}); n != 40 {
		t.Fatalf("sizeof(INPUT) = %d, want 40", n)
	}
	if off := unsafe.Offsetof(keybdInput{}.vk); off != 8 {
		t.Fatalf("KEYBDINPUT starts at %d, want 8", off)
	}
}

// The handle recover ends a stuck daemon by is the one opened on that pid:
// Wait times out while it runs, Terminate ends it, Wait then sees it gone.
// The process is this test's own child.
func TestWinProc_Windows_TerminateEndsThatPid(t *testing.T) {
	child := exec.Command("ping.exe", "-n", "30", "127.0.0.1") // no cmd.exe: nothing left behind
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() { _ = child.Wait(); close(done) }()
	if !pidAlive(child.Process.Pid) {
		t.Fatal("pidAlive(running child) = false")
	}
	p, err := openWinProc(child.Process.Pid)
	if err != nil {
		t.Fatal(err)
	}
	defer p.Close()
	if p.Wait(200 * time.Millisecond) {
		t.Fatal("Wait on a running process reported an exit")
	}
	if err := p.Terminate(); err != nil {
		t.Fatalf("Terminate: %v", err)
	}
	if !p.Wait(5 * time.Second) {
		t.Fatal("process still running after Terminate")
	}
	<-done
	if pidAlive(child.Process.Pid) {
		t.Fatal("pidAlive after the process ended = true")
	}
}
