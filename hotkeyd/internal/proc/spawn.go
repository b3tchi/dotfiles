package proc

import (
	"os"
	"os/exec"
	"strconv"
	"syscall"
)

// Run starts command (via "/bin/sh -c") detached from the daemon: its own
// session (setsid), free of the daemon's own file descriptors -- the X11
// connection and the i3 IPC socket named as the concrete risk -- and
// reaped in the background so it never accumulates as a zombie. Returns
// once the child has started; it does not wait for the child to finish.
//
// Mirrors hotkeyd.py's _dispatch's
// subprocess.Popen(cmd, shell=True, start_new_session=True): shell=True
// for the same reason (bind-table actions are plain shell command
// strings, dwm config.h style), start_new_session=True is Setsid below.
func Run(command string) error {
	cmd := exec.Command("/bin/sh", "-c", command)
	_, err := start(cmd)
	return err
}

// start is Run's shared plumbing. Tests call it directly to inspect the
// spawned *exec.Cmd (pid, captured stdio via a caller-supplied
// Stdout/Stderr) without racing fire-and-forget Run.
func start(cmd *exec.Cmd) (*exec.Cmd, error) {
	// New session: a signal to the daemon's process group (its
	// controlling terminal going away, a session-leader SIGHUP/SIGTERM)
	// must not reach a spawned action -- the action's job is to outlive
	// whatever triggered it, not share the daemon's fate.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}

	// Structural fd-leak guard: mark every fd currently open in THIS
	// process as close-on-exec, so the child gets nothing beyond what
	// cmd explicitly wires up (stdin/stdout/stderr). This does not
	// trust that every socket elsewhere in the daemon (internal/x11,
	// internal/i3) remembered to set CLOEXEC itself -- it enforces the
	// invariant here, once, regardless of how those fds were created.
	closeOnExecOpenFDs()

	if err := cmd.Start(); err != nil {
		return nil, err
	}
	// Reap in the background so a spawned action never becomes a
	// zombie; Run() itself does not block on the child's exit.
	go func() {
		_ = cmd.Wait()
	}()
	return cmd, nil
}

// closeOnExecOpenFDs marks every currently-open file descriptor above
// stderr as close-on-exec by reading /proc/self/fd (Linux-only, matching
// this repo's zero-dependency X11 daemon, which only ever runs on
// Linux). Best-effort: a listing that can't be read, or a race where an
// fd closes between listing and fcntl, is silently ignored -- this is a
// defense-in-depth sweep, not the only thing standing between a leaked
// socket and a spawned child (fds the standard library creates are
// already CLOEXEC by default).
func closeOnExecOpenFDs() {
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		return
	}
	for _, e := range entries {
		fd, err := strconv.Atoi(e.Name())
		if err != nil || fd <= 2 {
			continue
		}
		// syscall.FcntlInt does not exist in the stdlib syscall
		// package (only in golang.org/x/sys/unix, a third-party
		// dependency adr0018 forbids) -- call SYS_FCNTL directly,
		// the same raw syscall the unexported stdlib fcntl() helper
		// itself makes.
		_, _, _ = syscall.Syscall(syscall.SYS_FCNTL, uintptr(fd), uintptr(syscall.F_SETFD), uintptr(syscall.FD_CLOEXEC))
	}
}
