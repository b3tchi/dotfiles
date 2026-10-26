package proc

import (
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

// scratch is a private directory removed best-effort at the end: a probe
// may still be exiting, and Windows will not delete a running image.
func scratch(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("", "hotkeyd-proc-")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		for i := 0; i < 50; i++ {
			if os.RemoveAll(dir) == nil {
				return
			}
			time.Sleep(100 * time.Millisecond)
		}
	})
	return dir
}

// oddHome is a %USERPROFILE% with a space and a non-ASCII letter in it,
// holding a copy of this binary as probe.exe.
func oddHome(t *testing.T, base string) string {
	t.Helper()
	home := filepath.Join(base, "Jan Bečka")
	copyExe(t, filepath.Join(home, "probe.exe"))
	t.Setenv("USERPROFILE", home)
	return home
}

// releaseProbes creates the go file at the end of a test, so every probe
// still waiting answers and exits before scratch removes its image.
func releaseProbes(t *testing.T, goFile string) {
	t.Cleanup(func() {
		_ = os.WriteFile(goFile, nil, 0o644)
		time.Sleep(300 * time.Millisecond)
	})
}

func TestSplitCommand(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"~/x.exe a b", []string{"~/x.exe", "a", "b"}},
		{"  wt.exe   -w  new ", []string{"wt.exe", "-w", "new"}},
		{`"C:\Program Files\x.exe" "c d" e`, []string{`C:\Program Files\x.exe`, "c d", "e"}},
		{`a ""`, []string{"a", ""}},
	}
	for _, c := range cases {
		got, err := SplitCommand(c.in)
		if err != nil || !reflect.DeepEqual(got, c.want) {
			t.Errorf("SplitCommand(%q) = %q, %v; want %q", c.in, got, err, c.want)
		}
	}
	for _, bad := range []string{"", "   ", `x "unterminated`} {
		if _, err := SplitCommand(bad); err == nil {
			t.Errorf("SplitCommand(%q) succeeded, want an error", bad)
		}
	}
}

// A Run of "~/probe.exe a b" starts %USERPROFILE%\probe.exe itself - its
// parent is this process, so no shell sits between - with exactly the
// arguments a b, in %USERPROFILE%, with no console, under the detach
// flags. The home has a space and a non-ASCII letter (syscall.EscapeArg).
func TestRun_StartsHomeExeWithArgsInHomeNoShell(t *testing.T) {
	base := scratch(t)
	home := oddHome(t, base)
	t.Setenv(helperEnv, "probe")
	t.Setenv("PROBE_DIR", base)
	t.Setenv("PROBE_GO", "")

	cmd, err := spawn("~/probe.exe a b")
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}
	// The breakaway half of the flags depends on the job this test runs
	// in (WSL interop's forbids it); the job tests below pin it down.
	if got := cmd.SysProcAttr.CreationFlags; got&(detachedProcess|createNewProcessGroup) != detachedProcess|createNewProcessGroup {
		t.Errorf("creation flags = %#x, want DETACHED_PROCESS|CREATE_NEW_PROCESS_GROUP in them", got)
	}
	if !cmd.SysProcAttr.NoInheritHandles {
		t.Errorf("handles are inherited")
	}
	rep := readProbe(t, base, cmd.Process.Pid)

	want := []string{filepath.Join(home, "probe.exe"), "a", "b"}
	if !reflect.DeepEqual(rep.Args, want) {
		t.Errorf("child argv = %q, want %q", rep.Args, want)
	}
	if !strings.EqualFold(filepath.Clean(rep.Cwd), filepath.Clean(home)) {
		t.Errorf("child cwd = %q, want %q", rep.Cwd, home)
	}
	if rep.PPID != os.Getpid() {
		t.Errorf("child parent pid = %d, want this process %d (a shell in between?)", rep.PPID, os.Getpid())
	}
	if rep.Console {
		t.Errorf("child has a console (parent has one: %v); DETACHED_PROCESS should leave it none", hasConsole())
	}
}

func TestRun_QuotedArgumentWithSpaceIsOneArgument(t *testing.T) {
	base := scratch(t)
	home := oddHome(t, base)
	t.Setenv(helperEnv, "probe")
	t.Setenv("PROBE_DIR", base)
	t.Setenv("PROBE_GO", "")

	cmd, err := spawn(`~/probe.exe "c d" ~/e ž`)
	if err != nil {
		t.Fatalf("spawn: %v", err)
	}
	rep := readProbe(t, base, cmd.Process.Pid)
	want := []string{filepath.Join(home, "probe.exe"), "c d", filepath.Join(home, "e"), "ž"}
	if !reflect.DeepEqual(rep.Args, want) {
		t.Errorf("child argv = %q, want %q", rep.Args, want)
	}
}

// A missing program is an error naming the path and the Windows code; the
// caller (the daemon) logs it and carries on.
func TestRun_MissingExeNamesPathAndCode(t *testing.T) {
	base := scratch(t)
	home := oddHome(t, base)
	err := Run("~/nope.exe x")
	if err == nil {
		t.Fatal("Run of a missing exe succeeded")
	}
	msg := err.Error()
	if !strings.Contains(msg, filepath.Join(home, "nope.exe")) || !strings.Contains(msg, "error 2") {
		t.Fatalf("error %q does not name the path and error 2", msg)
	}
}

// The program outlives the process that started it, even when that
// process dies inside a job that kills everything on close: the start
// broke away. Mutation: drop CREATE_BREAKAWAY_FROM_JOB from DetachFlags and
// this goes red (the job takes the probe with it).
func TestRun_ChildOutlivesKilledSpawnerInKillOnCloseJob(t *testing.T) {
	base := scratch(t)
	oddHome(t, base)
	goFile := filepath.Join(base, "go")
	releaseProbes(t, goFile)
	ready := filepath.Join(base, "ready")

	sp := startHelper(t, "spawner",
		"SPAWNER_JOB=killonclose", "SPAWNER_CMD=~/probe.exe outlive", "SPAWNER_RUNS=1",
		"SPAWNER_READY="+ready, "SPAWNER_LOG="+filepath.Join(base, "log"), "SPAWNER_WAIT=1",
		"PROBE_DIR="+base, "PROBE_GO="+goFile)
	got := waitFile(t, ready, 15*time.Second)
	if strings.HasPrefix(got, "ERR") {
		t.Fatalf("spawner: %s", got)
	}
	pidStr, flags, _ := strings.Cut(got, ":")
	pid, _ := strconv.Atoi(pidStr)
	if flags != fmt.Sprintf("%#x", DetachFlags) {
		t.Fatalf("spawner started the probe with flags %s, want %#x - the job refused breakaway?", flags, DetachFlags)
	}
	rep := readProbe(t, base, pid)
	if rep.PPID != sp.Process.Pid {
		t.Fatalf("probe parent = %d, want the spawner %d", rep.PPID, sp.Process.Pid)
	}

	// End the spawner - our own child, by its handle - and with it the
	// last handle to its kill-on-close job.
	if err := sp.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = sp.Wait()
	time.Sleep(200 * time.Millisecond)

	if err := os.WriteFile(goFile, nil, 0o644); err != nil {
		t.Fatal(err)
	}
	answered := waitFile(t, filepath.Join(base, fmt.Sprintf("%d.answered", pid)), 10*time.Second)
	if answered != strconv.Itoa(pid) {
		t.Fatalf("answer %q, want the probe's pid %d", answered, pid)
	}
}

// Inside a job that forbids breakaway, a start retries without the flag
// and says so once - not once per start.
func TestRun_JobForbidsBreakaway_RetriesAndSaysOnce(t *testing.T) {
	base := scratch(t)
	oddHome(t, base)
	ready := filepath.Join(base, "ready")
	logFile := filepath.Join(base, "log")

	sp := startHelper(t, "spawner",
		"SPAWNER_JOB=nobreakaway", "SPAWNER_CMD=~/probe.exe kept", "SPAWNER_RUNS=2",
		"SPAWNER_READY="+ready, "SPAWNER_LOG="+logFile,
		"PROBE_DIR="+base, "PROBE_GO=")
	got := waitFile(t, ready, 15*time.Second)
	if strings.HasPrefix(got, "ERR") {
		t.Fatalf("spawner: %s", got)
	}
	_ = sp.Wait()
	starts := strings.Fields(got)
	if len(starts) != 2 {
		t.Fatalf("spawner reported %q, want two starts", got)
	}
	want := fmt.Sprintf("%#x", DetachFlags&^createBreakawayFromJob)
	for _, s := range starts {
		pidStr, flags, _ := strings.Cut(s, ":")
		if flags != want {
			t.Errorf("start %s: flags %s, want the retry's %s", s, flags, want)
		}
		pid, _ := strconv.Atoi(pidStr)
		if rep := readProbe(t, base, pid); rep.PPID != sp.Process.Pid {
			t.Errorf("probe %d parent = %d, want the spawner %d", pid, rep.PPID, sp.Process.Pid)
		}
	}
	data, _ := os.ReadFile(logFile)
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 1 || !strings.Contains(lines[0], "forbids breakaway") {
		t.Fatalf("log = %q, want exactly one line saying the job forbids breakaway", string(data))
	}
}
