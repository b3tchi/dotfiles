package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"hotkeyd/internal/i3"
)

func main() { os.Exit(run(os.Args[1:], os.Stdout, os.Stderr)) }

func run(argv []string, out, errOut *os.File) int {
	fs := flag.NewFlagSet("livecheck", flag.ContinueOnError)
	fs.SetOutput(errOut)
	display := fs.String("display", "", "the PRIVATE X display to run against (required; never inherited from $DISPLAY)")
	binFlag := fs.String("hotkeyd", "", "the hotkeyd binary to drive (default: $HOTKEYD_BIN, else `hotkeyd` next to this binary)")
	i3sockFlag := fs.String("i3sock", "", "the rig i3's IPC socket (default: `i3 --get-socketpath` with DISPLAY pinned to the rig)")
	if err := fs.Parse(argv); err != nil {
		return 2
	}

	target, err := resolveTargetDisplay(*display, os.Getenv)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 2
	}

	rep := NewReporter(out)
	defer rep.Summary()

	// Runtime dir: the daemon's lock, state socket and grab report all live
	// under it, and this process reads them through internal/layer and
	// internal/proc, which resolve $XDG_RUNTIME_DIR at CALL time. Pinning it
	// here keeps every one of those paths inside the rig.
	runtimeDir, err := os.MkdirTemp("", "hkl-rt-")
	if err != nil {
		fmt.Fprintln(errOut, "livecheck: temp dir:", err)
		return 2
	}
	defer os.RemoveAll(runtimeDir)
	os.Setenv("XDG_RUNTIME_DIR", runtimeDir)

	rig, err := OpenRig(target)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return 2
	}
	defer rig.Close()

	inj := NewInjector(target)
	if !inj.Available() {
		fmt.Fprintln(errOut, "livecheck: xdotool is not on PATH — every claim that needs injected input will SKIP")
	}

	i3sock := *i3sockFlag
	if i3sock == "" {
		i3sock = discoverRigI3Socket(target)
	}

	runMechanism(rep, rig, inj, i3sock)
	rig.ReleaseAll()

	runI3ClientChecks(rep, target, i3sock)

	bin := daemonBinary(*binFlag)
	if len(bin) == 0 {
		rep.Skip("the real Go daemon under Xvfb + real i3", "no hotkeyd binary given (--hotkeyd or $HOTKEYD_BIN)")
		return rep.ExitCode()
	}
	if i3sock == "" {
		rep.Skip("the real Go daemon under Xvfb + real i3", "no rig i3 socket could be resolved")
		return rep.ExitCode()
	}

	if err := runDaemonPhase(rep, rig, inj, bin, target, runtimeDir, i3sock); err != nil {
		fmt.Fprintln(errOut, "livecheck:", err)
	}
	rig.ReleaseAll()
	if err := runModOnePhase(rep, rig, inj, bin, target, runtimeDir, i3sock); err != nil {
		fmt.Fprintln(errOut, "livecheck:", err)
	}
	rig.ReleaseAll()

	return rep.ExitCode()
}

// daemonBinary resolves the daemon under test: --hotkeyd, else $HOTKEYD_BIN
// (which test-hotkeyd.sh already uses as its parity seam, and which may
// carry arguments), else a `hotkeyd` sitting next to this binary.
func daemonBinary(flagVal string) []string {
	if flagVal != "" {
		return strings.Fields(flagVal)
	}
	if env := os.Getenv("HOTKEYD_BIN"); env != "" {
		return strings.Fields(env)
	}
	self, err := os.Executable()
	if err != nil {
		return nil
	}
	cand := filepath.Join(filepath.Dir(self), "hotkeyd")
	if st, err := os.Stat(cand); err == nil && !st.IsDir() {
		return []string{cand}
	}
	return nil
}

// discoverRigI3Socket asks the RIG's i3 for its socket, with DISPLAY pinned
// and I3SOCK scrubbed — never the ambient $I3SOCK, which on a developer
// machine points at their real session.
func discoverRigI3Socket(display string) string {
	cmd := exec.Command("i3", "--get-socketpath")
	cmd.Env = childEnv(os.Environ(), display, "")
	out, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// runI3ClientChecks drives internal/i3's REAL client against the REAL i3 —
// the Go twin of live_check.py's persistent-IPC section.
func runI3ClientChecks(rep *Reporter, display, sock string) {
	if sock == "" {
		rep.Skip("i3 dispatch over the persistent socket returned success", "no rig i3 socket could be resolved")
		return
	}
	client := i3.NewClient(func() (string, error) { return sock, nil }, func(uint32, map[string]any) {})
	defer client.Close()

	const mark = "hotkeyd-live-go"
	ok, errMsg, err := client.Command("mark --add " + mark)
	rep.Check(err == nil && ok, "i3 dispatch over the persistent socket returned success",
		fmt.Sprintf("err=%v i3=%q", err, errMsg))

	marks, _ := i3msg(sock, display, "-t", "get_marks")
	rep.Check(strings.Contains(marks, mark), "i3 accepted the command", strings.TrimSpace(marks))
	_, _ = i3msg(sock, display, "unmark", mark)

	fdBefore, hadBefore := client.Fileno()
	for i := 0; i < 120; i++ {
		if _, _, err := client.Command(fmt.Sprintf("nop live %d", i)); err != nil {
			rep.Check(false, "one connection survived 120+ dispatches", fmt.Sprintf("dispatch %d failed: %v", i, err))
			return
		}
	}
	fdAfter, hadAfter := client.Fileno()
	// Stronger than live_check.py's `_sock is not None`: the SAME file
	// descriptor before and after means no reconnect happened in between,
	// which is what "persistent" actually claims.
	rep.Check(hadBefore && hadAfter && fdBefore == fdAfter,
		"one connection survived 120+ dispatches — the same fd before and after",
		fmt.Sprintf("fd %d -> %d", fdBefore, fdAfter))
}

func runDaemonPhase(rep *Reporter, rig *Rig, inj *Injector, bin []string, display, runtimeDir, i3sock string) error {
	proxy, err := StartI3Proxy(filepath.Join(runtimeDir, "i3-proxy.sock"), i3sock)
	if err != nil {
		return err
	}
	defer proxy.Close()

	d, err := NewDaemonRig(bin, display, runtimeDir)
	if err != nil {
		return err
	}
	defer d.Cleanup()
	d.Proxy = proxy

	// The baseline is taken BEFORE the daemon starts, so the startup grab
	// sync is itself an observed PUBLICATION rather than an inference off a
	// report that may not exist yet (settle.go).
	startWatch := watchGrabs(display)
	if err := d.Start(proxy.path, 15*time.Second); err != nil {
		rep.Check(false, "the real daemon started and announced its grab set", err.Error())
		return nil
	}
	sw, err := WatchState(stateSocketPath(display))
	if err != nil {
		rep.Check(false, "the daemon published a state socket", err.Error())
		return nil
	}
	d.State = sw
	if ok, why := startWatch.settled(grabSettleTimeout); !ok {
		fmt.Fprintln(os.Stderr, "livecheck: the daemon's startup grab set never settled:", why)
	}

	runDaemonChecks(rep, rig, inj, d)
	runSingleInstanceCheck(rep, d)
	d.Stop()
	return nil
}

// runModOnePhase merges `i3wm.mod: Mod1` onto the live display and restarts
// the daemon against it. The resource is merged AFTER i3 connected,
// deliberately: X discards root properties when the last client
// disconnects, so a resource written before the WM is up does not survive to
// be read.
func runModOnePhase(rep *Reporter, rig *Rig, inj *Injector, bin []string, display, runtimeDir, i3sock string) error {
	if _, err := exec.LookPath("xrdb"); err != nil {
		rep.Skip("the daemon detected $mod=Mod1 for itself on a display carrying i3wm.mod: Mod1",
			"xrdb is not on PATH, so no i3wm.mod resource could be merged")
		return nil
	}
	if err := xrdb(display, "-merge", "i3wm.mod:\tMod1\n"); err != nil {
		rep.Skip("the daemon detected $mod=Mod1 for itself on a display carrying i3wm.mod: Mod1", err.Error())
		return nil
	}
	defer func() { _ = xrdb(display, "-load", "") }()

	proxy, err := StartI3Proxy(filepath.Join(runtimeDir, "i3-proxy-mod1.sock"), i3sock)
	if err != nil {
		return err
	}
	defer proxy.Close()

	d, err := NewDaemonRig(bin, display, runtimeDir)
	if err != nil {
		return err
	}
	defer d.Cleanup()
	d.Proxy = proxy

	startWatch := watchGrabs(display)
	if err := d.Start(proxy.path, 15*time.Second); err != nil {
		rep.Check(false, "the daemon started on the Mod1 display", err.Error())
		return nil
	}
	sw, err := WatchState(stateSocketPath(display))
	if err != nil {
		rep.Check(false, "the Mod1 daemon published a state socket", err.Error())
		return nil
	}
	d.State = sw
	if ok, why := startWatch.settled(grabSettleTimeout); !ok {
		fmt.Fprintln(os.Stderr, "livecheck: the Mod1 daemon's startup grab set never settled:", why)
	}

	runModOneChecks(rep, rig, inj, d)
	d.Stop()
	return nil
}

func xrdb(display string, mode, content string) error {
	cmd := exec.Command("xrdb", mode, "-")
	cmd.Env = childEnv(os.Environ(), display, "")
	cmd.Stdin = strings.NewReader(content)
	out, err := cmd.CombinedOutput()
	if err != nil {
		return fmt.Errorf("xrdb %s: %w: %s", mode, err, strings.TrimSpace(string(out)))
	}
	return nil
}
