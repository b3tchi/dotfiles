package main

// kwi3-hoex.27: which kwi3-run.exe a Run starts on Windows. kwi3's
// i3kwin/runner/win32/deploy.sh puts each deploy in a NEW
// %LOCALAPPDATA%\kwi3\run\v<N> and only then rewrites
// %LOCALAPPDATA%\kwi3\run\current.txt (one CRLF line: that directory), and
// nothing puts it on PATH. So a Run whose program is the bare word
// kwi3-run.exe starts <current.txt's directory>\kwi3-run.exe, read afresh
// on EVERY start - a new deploy is used by the next chord, with no hotkeyd
// restart - and falls back to the PATH lookup only when there is no
// deployed copy. Portable (no build tag) so it is tested on Linux too;
// only win32run.go wires it in.
//
// kwi3-etpz: kwi3's scoop package installs hotkeyd.exe and kwi3-run.exe
// side by side (apps\kwi3\<version>). A kwi3-run.exe beside this
// executable is the runner of the same install, and it comes first:
// before current.txt, then PATH.

import (
	"errors"
	"fmt"
	"io/fs"
	"strings"
	"sync"
)

// kwi3RunExe is the program word a Run names the runner by (host_win32.go
// overlayCmd()).
const kwi3RunExe = "kwi3-run.exe"

// runFS is the file system the resolver reads: os.ReadFile and os.Stat in
// production, a map in a test.
type runFS struct {
	ReadFile func(string) ([]byte, error)
	Stat     func(string) (fs.FileInfo, error)
}

// winAbs reports whether p is an absolute Windows path: a drive (`C:\`)
// or a UNC/device path (`\\...`).
func winAbs(p string) bool {
	if strings.HasPrefix(p, `\\`) || strings.HasPrefix(p, `//`) {
		return true
	}
	return len(p) >= 3 && p[1] == ':' && (p[2] == '\\' || p[2] == '/')
}

// resolveKwi3Run returns the deployed runner current.txt names under
// localAppData, or "" and why there is none. current.txt's first line is
// the version directory - absolute as deploy.sh writes it, or a name
// relative to the run directory - with a UTF-8 BOM, surrounding blanks, a
// CR and a trailing backslash ignored.
func resolveKwi3Run(localAppData string, f runFS) (path, why string) {
	if strings.TrimSpace(localAppData) == "" {
		return "", "%LOCALAPPDATA% is unset"
	}
	runDir := strings.TrimRight(localAppData, `\/`) + `\kwi3\run`
	cur := runDir + `\current.txt`
	b, err := f.ReadFile(cur)
	if errors.Is(err, fs.ErrNotExist) {
		return "", "no " + cur
	}
	if err != nil {
		return "", fmt.Sprintf("cannot read %s: %s", cur, err)
	}
	line := strings.TrimPrefix(string(b), "\ufeff")
	if i := strings.IndexAny(line, "\r\n"); i >= 0 {
		line = line[:i]
	}
	dir := strings.TrimRight(strings.TrimSpace(line), `\/`)
	if dir == "" {
		return "", cur + " is empty"
	}
	if !winAbs(dir) {
		dir = runDir + `\` + dir
	}
	if fi, err := f.Stat(dir); err != nil || !fi.IsDir() {
		return "", fmt.Sprintf("%s names %s, which is not a directory", cur, dir)
	}
	exe := dir + `\` + kwi3RunExe
	if fi, err := f.Stat(exe); err != nil || fi.IsDir() {
		return "", fmt.Sprintf("%s names %s, but there is no %s", cur, dir, exe)
	}
	return exe, ""
}

// kwi3RunStarter is the daemon's Run on Windows: a command whose first
// word is exactly kwi3-run.exe starts the deployed copy, anything else is
// passed to start unchanged. Which copy it used, or why it fell back to
// PATH, is said once - and again only when that answer changes (a
// redeploy, a deploy removed).
type kwi3RunStarter struct {
	start func(string) error
	// self is this executable's path (os.Executable); a kwi3-run.exe in
	// the same directory is started first. "" skips that lookup.
	self   string
	getenv func(string) string
	fs     runFS
	log    func(string)

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
		return s.start(`"` + exe + `"` + rest)
	}
	exe, why := resolveKwi3Run(s.getenv("LOCALAPPDATA"), s.fs)
	if exe != "" {
		s.say("kwi3-run: starting the deployed " + exe)
		// SplitCommand groups a quoted span: the path may hold spaces.
		return s.start(`"` + exe + `"` + rest)
	}
	s.say("kwi3-run: no deployed copy (" + why + "); looking kwi3-run.exe up on PATH")
	if err := s.start(command); err != nil {
		return fmt.Errorf("kwi3-run.exe not found: no deployed copy (%s), and not on PATH: %w", why, err)
	}
	return nil
}

// besideSelf is <self's directory>\kwi3-run.exe when that is a file, else
// "".
func besideSelf(self string, f runFS) string {
	i := strings.LastIndexAny(self, `\/`)
	if i < 0 {
		return ""
	}
	exe := self[:i] + `\` + kwi3RunExe
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
