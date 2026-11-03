package main

// Which kwi3-run.exe a Run starts on Windows. kwi3 is installed as one
// scoop package (kwi3-etpz), with hotkeyd.exe and kwi3-run.exe side by
// side in apps\kwi3\<version>: a Run whose program is the bare word
// kwi3-run.exe starts the kwi3-run.exe beside this executable - the runner
// of the same install - and falls back to the PATH lookup only when there
// is none beside it. kwi3-dfnb retired the %LOCALAPPDATA%\kwi3\run
// deploy (current.txt) this used to read between the two. Portable (no
// build tag); only win32run.go wires it in.

import (
	"fmt"
	"io/fs"
	"strings"
	"sync"
)

// kwi3RunExe is the program word a Run names the runner by (host_win32.go
// overlayCmd()).
const kwi3RunExe = "kwi3-run.exe"

// runFS is the file system the resolvers read: os.Stat in production, a
// map in a test.
type runFS struct {
	Stat func(string) (fs.FileInfo, error)
}

// kwi3RunStarter is the daemon's Run on Windows: a command whose first
// word is exactly kwi3-run.exe starts the copy beside this executable,
// anything else is passed to start unchanged. Which copy it used, or that
// it fell back to PATH, is said once - and again only when that answer
// changes.
type kwi3RunStarter struct {
	start func(string) error
	// self is this executable's path (os.Executable); a kwi3-run.exe in
	// the same directory is started first. "" skips that lookup.
	self string
	fs   runFS
	log  func(string)

	mu   sync.Mutex
	said string
}

// Run is DaemonConfig.Run.
func (s *kwi3RunStarter) Run(command string) error {
	rest, ok := strings.CutPrefix(command, kwi3RunExe)
	if !ok || (rest != "" && rest[0] != ' ' && rest[0] != '\t') {
		return s.start(command)
	}
	if exe := besideSelf(s.self, s.fs); exe != "" {
		s.say("kwi3-run: starting " + exe + ", beside hotkeyd")
		// SplitCommand groups a quoted span: the path may hold spaces.
		return s.start(`"` + exe + `"` + rest)
	}
	why := "no " + besidePath(s.self)
	s.say("kwi3-run: " + why + "; looking kwi3-run.exe up on PATH")
	if err := s.start(command); err != nil {
		return fmt.Errorf("kwi3-run.exe not found: %s, and not on PATH: %w", why, err)
	}
	return nil
}

// besidePath is <self's directory>\kwi3-run.exe, or a description when
// self has no directory (it could not be named).
func besidePath(self string) string {
	i := strings.LastIndexAny(self, `\/`)
	if i < 0 {
		return kwi3RunExe + " beside hotkeyd (its own path is unknown)"
	}
	return self[:i] + `\` + kwi3RunExe
}

// besideSelf is <self's directory>\kwi3-run.exe when that is a file, else
// "".
func besideSelf(self string, f runFS) string {
	if strings.LastIndexAny(self, `\/`) < 0 {
		return ""
	}
	exe := besidePath(self)
	if fi, err := f.Stat(exe); err != nil || fi.IsDir() {
		return ""
	}
	return exe
}

func (s *kwi3RunStarter) say(line string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if line != s.said {
		s.said = line
		s.log(line)
	}
}
