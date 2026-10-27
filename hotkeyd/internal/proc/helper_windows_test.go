package proc

// The Windows tests start real processes, and every one of them is this
// test binary again, told what to be by HOTKEYD_PROC_HELPER:
//
//	probe    the program a Run starts: reports its cwd, argv, parent pid and
//	         whether it has a console, then (if asked) waits for a "go" file
//	         and answers - the proof it is still alive.
//	spawner  a stand-in for hotkeyd: puts itself in a job, starts probes
//	         with Run, reports, then waits to be killed.
//	locker   a second hotkeyd for a lock: takes it, reports, waits.
//
// Each waits a bounded time and exits on its own, so a failing test
// leaves nothing running; the only process a test ends is its own child,
// through the handle it holds.

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
	"unsafe"
)

const helperEnv = "HOTKEYD_PROC_HELPER"

// helperLife bounds every helper's own life.
const helperLife = 60 * time.Second

func TestMain(m *testing.M) {
	switch os.Getenv(helperEnv) {
	case "":
		os.Exit(m.Run())
	case "probe":
		os.Exit(probeMain())
	case "spawner":
		os.Exit(spawnerMain())
	case "locker":
		os.Exit(lockerMain())
	default:
		fmt.Fprintf(os.Stderr, "unknown %s=%q\n", helperEnv, os.Getenv(helperEnv))
		os.Exit(2)
	}
}

type probeReport struct {
	PID     int      `json:"pid"`
	PPID    int      `json:"ppid"`
	Cwd     string   `json:"cwd"`
	Args    []string `json:"args"`
	Console bool     `json:"console"`
}

var procGetConsoleWindow = modkernel32.NewProc("GetConsoleWindow")

func hasConsole() bool {
	r, _, _ := procGetConsoleWindow.Call()
	return r != 0
}

// writeFileAtomic writes via a temp file and a rename, so a reader polling
// for path never sees it half-written.
func writeFileAtomic(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// probeMain: PROBE_DIR names a directory; the report goes to
// <dir>\<pid>.json. With PROBE_GO set, it then waits for that file and
// writes <dir>\<pid>.answered.
func probeMain() int {
	dir := os.Getenv("PROBE_DIR")
	cwd, _ := os.Getwd()
	rep := probeReport{PID: os.Getpid(), PPID: os.Getppid(), Cwd: cwd, Args: os.Args, Console: hasConsole()}
	data, _ := json.Marshal(rep)
	if err := writeFileAtomic(filepath.Join(dir, fmt.Sprintf("%d.json", rep.PID)), data); err != nil {
		return 1
	}
	goFile := os.Getenv("PROBE_GO")
	if goFile == "" {
		return 0
	}
	deadline := time.Now().Add(helperLife)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(goFile); err == nil {
			_ = writeFileAtomic(filepath.Join(dir, fmt.Sprintf("%d.answered", rep.PID)), []byte(strconv.Itoa(rep.PID)))
			return 0
		}
		time.Sleep(20 * time.Millisecond)
	}
	return 3
}

// Job objects, for the spawner.
var (
	procCreateJobObjectW         = modkernel32.NewProc("CreateJobObjectW")
	procSetInformationJobObject  = modkernel32.NewProc("SetInformationJobObject")
	procAssignProcessToJobObject = modkernel32.NewProc("AssignProcessToJobObject")
)

const (
	jobObjectExtendedLimitInformation = 9
	jobLimitBreakawayOK               = 0x00000800
	jobLimitKillOnJobClose            = 0x00002000
)

type jobBasicLimit struct {
	PerProcessUserTimeLimit int64
	PerJobUserTimeLimit     int64
	LimitFlags              uint32
	MinimumWorkingSetSize   uintptr
	MaximumWorkingSetSize   uintptr
	ActiveProcessLimit      uint32
	Affinity                uintptr
	PriorityClass           uint32
	SchedulingClass         uint32
}

type jobExtendedLimit struct {
	Basic                 jobBasicLimit
	IoCounters            [6]uint64
	ProcessMemoryLimit    uintptr
	JobMemoryLimit        uintptr
	PeakProcessMemoryUsed uintptr
	PeakJobMemoryUsed     uintptr
}

// joinNewJob puts this process into a fresh job with limitFlags. The
// handle is deliberately never closed: it closes when this process dies,
// and with KILL_ON_JOB_CLOSE that kills everything still in the job.
func joinNewJob(limitFlags uint32) error {
	h, _, err := procCreateJobObjectW.Call(0, 0)
	if h == 0 {
		return fmt.Errorf("CreateJobObject: %w", err)
	}
	info := jobExtendedLimit{Basic: jobBasicLimit{LimitFlags: limitFlags}}
	if r, _, err := procSetInformationJobObject.Call(h, jobObjectExtendedLimitInformation, uintptr(unsafe.Pointer(&info)), unsafe.Sizeof(info)); r == 0 {
		return fmt.Errorf("SetInformationJobObject: %w", err)
	}
	self, _ := syscall.GetCurrentProcess()
	if r, _, err := procAssignProcessToJobObject.Call(h, uintptr(self)); r == 0 {
		return fmt.Errorf("AssignProcessToJobObject: %w", err)
	}
	return nil
}

// spawnerMain: SPAWNER_JOB is "killonclose" (KILL_ON_JOB_CLOSE |
// BREAKAWAY_OK) or "nobreakaway" (a job that forbids breakaway);
// SPAWNER_CMD is run SPAWNER_RUNS times; what proc.Log says goes to
// SPAWNER_LOG; SPAWNER_READY gets the started pids (or the error). With
// SPAWNER_WAIT set it then waits to be killed.
func spawnerMain() int {
	var flags uint32
	switch os.Getenv("SPAWNER_JOB") {
	case "killonclose":
		flags = jobLimitKillOnJobClose | jobLimitBreakawayOK
	case "nobreakaway":
		flags = 0
	}
	ready := os.Getenv("SPAWNER_READY")
	if err := joinNewJob(flags); err != nil {
		_ = writeFileAtomic(ready, []byte("ERR "+err.Error()))
		return 1
	}
	logFile := os.Getenv("SPAWNER_LOG")
	Log = func(msg string) {
		f, err := os.OpenFile(logFile, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
		if err == nil {
			fmt.Fprintln(f, msg)
			f.Close()
		}
	}
	os.Setenv(helperEnv, "probe")
	runs, _ := strconv.Atoi(os.Getenv("SPAWNER_RUNS"))
	var pids []string
	for i := 0; i < runs; i++ {
		cmd, err := spawn(os.Getenv("SPAWNER_CMD"))
		if err != nil {
			_ = writeFileAtomic(ready, []byte("ERR "+err.Error()))
			return 1
		}
		pids = append(pids, fmt.Sprintf("%d:%#x", cmd.Process.Pid, cmd.SysProcAttr.CreationFlags))
	}
	_ = writeFileAtomic(ready, []byte(strings.Join(pids, " ")))
	if os.Getenv("SPAWNER_WAIT") != "" {
		time.Sleep(helperLife)
	}
	return 0
}

// lockerMain takes LOCKER_PATH's lock, writes LOCKER_READY, and holds it.
func lockerMain() int {
	ready := os.Getenv("LOCKER_READY")
	l, err := AcquireLock(os.Getenv("LOCKER_PATH"))
	if err != nil {
		_ = writeFileAtomic(ready, []byte("ERR "+err.Error()))
		return 1
	}
	_ = writeFileAtomic(ready, []byte(strconv.Itoa(os.Getpid())))
	if os.Getenv("LOCKER_RELEASE") != "" {
		// A clean shutdown: release at once and exit (kwi3-hoex.30).
		l.Release()
		return 0
	}
	time.Sleep(helperLife)
	l.Release()
	return 0
}

// startHelper starts this test binary as helper kind with extra env, and
// arranges for it to be ended (by its own handle) when the test ends.
func startHelper(t *testing.T, kind string, env ...string) *exec.Cmd {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	cmd := exec.Command(exe)
	cmd.Env = append(append(os.Environ(), helperEnv+"="+kind), env...)
	cmd.Stdout, cmd.Stderr = os.Stderr, os.Stderr
	if err := cmd.Start(); err != nil {
		t.Fatalf("start %s helper: %v", kind, err)
	}
	t.Cleanup(func() {
		if cmd.ProcessState == nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
	})
	return cmd
}

// waitFile polls for path and returns its content, failing after timeout.
func waitFile(t *testing.T, path string, timeout time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for {
		data, err := os.ReadFile(path)
		if err == nil {
			return string(data)
		}
		if time.Now().After(deadline) {
			t.Fatalf("%s did not appear within %v", path, timeout)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func readProbe(t *testing.T, dir string, pid int) probeReport {
	t.Helper()
	data := waitFile(t, filepath.Join(dir, fmt.Sprintf("%d.json", pid)), 15*time.Second)
	var rep probeReport
	if err := json.Unmarshal([]byte(data), &rep); err != nil {
		t.Fatalf("probe report %q: %v", data, err)
	}
	return rep
}

// copyExe copies this test binary to dst, the program a Run will start.
func copyExe(t *testing.T, dst string) {
	t.Helper()
	exe, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(exe)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dst, data, 0o755); err != nil {
		t.Fatal(err)
	}
}
