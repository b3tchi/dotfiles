package proc

import (
	"errors"
	"fmt"
	"io/fs"
	"os/exec"
	"strings"
	"sync"
	"syscall"
)

// Process creation flags every Run start carries on Windows (sp012 plan):
// no console (the daemon is a -H windowsgui program and so is everything it
// starts unless the program opens its own window), its own process group
// (a console Ctrl+C aimed at the daemon's group never reaches it), and out
// of any job the daemon runs in, so a job that kills on close - a rig's, a
// launcher's - does not take every program started from a chord with it.
const (
	detachedProcess        = 0x00000008
	createNewProcessGroup  = 0x00000200
	createBreakawayFromJob = 0x01000000

	// DetachFlags is what a start is first tried with.
	DetachFlags = detachedProcess | createNewProcessGroup | createBreakawayFromJob

	errorAccessDenied = syscall.Errno(5)
	errorFileNotFound = syscall.Errno(2)
)

// breakawayRefused is said once per process: the first start that a job
// refused to let break away, and that then started without the flag.
var breakawayRefused sync.Once

// Run starts command detached from the daemon. There is no shell on
// Windows: the command is split into words (SplitCommand), a leading "~"
// in any word is %USERPROFILE% (ExpandHome), and the first word is the
// program - an absolute path, or a name looked up on %PATH% the way
// CreateProcess callers expect. Arguments reach the program through
// syscall.EscapeArg (os/exec builds the command line with it), so a path
// with spaces or non-ASCII arrives as one argument. The working directory
// is %USERPROFILE%, no handle is inherited, and the child is reaped in the
// background. Returns once the child has started.
//
// A start that fails names the program and the Windows error code; the
// daemon logs it and keeps serving (daemon.go's dispatch).
func Run(command string) error {
	_, err := spawn(command)
	return err
}

// spawn is Run's plumbing; tests call it to read the started *exec.Cmd.
func spawn(command string) (*exec.Cmd, error) {
	argv, err := SplitCommand(command)
	if err != nil {
		return nil, err
	}
	for i := range argv {
		argv[i] = ExpandHome(argv[i])
	}
	build := func(flags uint32) *exec.Cmd {
		c := exec.Command(argv[0], argv[1:]...)
		c.Dir = HomeDir()
		c.SysProcAttr = &syscall.SysProcAttr{CreationFlags: flags, NoInheritHandles: true}
		return c
	}

	cmd := build(DetachFlags)
	err = cmd.Start()
	if err != nil && errors.Is(err, errorAccessDenied) {
		// A job without JOB_OBJECT_LIMIT_BREAKAWAY_OK refuses the
		// breakaway flag with ACCESS_DENIED. Try once without it; only a
		// start that then succeeds proves it was the job, so only then is
		// it said.
		// ACCESS_DENIED for the breakaway is checked before the program
		// is even looked for, so a retry that fails too has the real
		// error (a missing exe is ERROR_FILE_NOT_FOUND there).
		retry := build(DetachFlags &^ createBreakawayFromJob)
		err = retry.Start()
		if err == nil {
			breakawayRefused.Do(func() {
				Log("run: this process's job forbids breakaway; programs started from now on stay in that job")
			})
			cmd = retry
		}
	}
	if err != nil {
		return nil, fmt.Errorf("start %s: %w (error %d)", argv[0], err, errorCode(err))
	}
	go func() { _ = cmd.Wait() }()
	return cmd, nil
}

// errorCode is the Windows error code behind err. exec's lookup of a
// missing absolute path reports fs.ErrNotExist without the Errno, which is
// ERROR_FILE_NOT_FOUND.
func errorCode(err error) int {
	var no syscall.Errno
	if errors.As(err, &no) {
		return int(no)
	}
	if errors.Is(err, fs.ErrNotExist) {
		return int(errorFileNotFound)
	}
	return -1
}

// SplitCommand splits a Run command into words: runs of spaces or tabs
// separate words, and a double-quoted span is part of one word with the
// quotes removed (`"C:\Program Files\x.exe" a` is two words). There is no
// other escaping; an unterminated quote is an error, never a guess.
func SplitCommand(command string) ([]string, error) {
	var words []string
	var cur strings.Builder
	inWord, inQuote := false, false
	for _, r := range command {
		switch {
		case r == '"':
			inQuote = !inQuote
			inWord = true
		case (r == ' ' || r == '\t') && !inQuote:
			if inWord {
				words = append(words, cur.String())
				cur.Reset()
				inWord = false
			}
		default:
			cur.WriteRune(r)
			inWord = true
		}
	}
	if inQuote {
		return nil, fmt.Errorf("run %q: unterminated quote", command)
	}
	if inWord {
		words = append(words, cur.String())
	}
	if len(words) == 0 {
		return nil, fmt.Errorf("run %q: no program named", command)
	}
	return words, nil
}
