package main

// kwi3-wv1u: which terminal $mod+Return starts on Windows. The table names
// it `wezterm-gui.exe start` (host_win32.go); Jan installs WezTerm with
// scoop, whose shim directory may not be on hotkeyd's PATH and whose shim
// is a console program, so the real GUI exe is looked for first:
// %SCOOP%\apps\wezterm\current\wezterm-gui.exe, else
// %USERPROFILE%\scoop\apps\wezterm\current\wezterm-gui.exe. Then PATH.
// And with no WezTerm anywhere, Windows Terminal (`wt.exe -w new`, the
// chord's command before kwi3-wv1u), said once. `wezterm-gui.exe start`
// is a new window every time: a running WezTerm GUI is asked over its
// socket to open one (prefer_to_spawn_tabs is false), anything else starts
// one. Portable (no build tag) so it is tested on Linux too; only
// win32run.go wires it in.

import (
	"fmt"
	"strings"
	"sync"
)

const (
	wezGuiExe  = "wezterm-gui.exe"
	wtFallback = "wt.exe -w new"
)

// wezTermCandidates is where scoop puts WezTerm, in the order tried.
func wezTermCandidates(getenv func(string) string) []string {
	var out []string
	for _, root := range []string{
		getenv("SCOOP"),
		strings.TrimRight(getenv("USERPROFILE"), `\/`) + `\scoop`,
	} {
		root = strings.TrimRight(strings.TrimSpace(root), `\/`)
		if root == "" || root == `\scoop` {
			continue
		}
		out = append(out, root+`\apps\wezterm\current\`+wezGuiExe)
	}
	return out
}

// termStarter wraps the daemon's start: a command whose first word is
// exactly wezterm-gui.exe is resolved as above; anything else passes
// through unchanged. What it used is said once, and again only when that
// answer changes.
type termStarter struct {
	start  func(string) error
	getenv func(string) string
	fs     runFS
	log    func(string)

	mu   sync.Mutex
	said string
}

// Run is DaemonConfig.Run.
func (s *termStarter) Run(command string) error {
	rest, ok := strings.CutPrefix(command, wezGuiExe)
	if !ok || (rest != "" && rest[0] != ' ' && rest[0] != '\t') {
		return s.start(command)
	}
	cands := wezTermCandidates(s.getenv)
	for _, exe := range cands {
		if fi, err := s.fs.Stat(exe); err == nil && !fi.IsDir() {
			s.say("terminal: starting WezTerm " + exe)
			// SplitCommand groups a quoted span: the path may hold spaces.
			return s.start(`"` + exe + `"` + rest)
		}
	}
	where := "no " + strings.Join(cands, ", no ")
	if len(cands) == 0 {
		where = "%SCOOP% and %USERPROFILE% unset"
	}
	pathErr := s.start(command)
	if pathErr == nil {
		s.say("terminal: " + where + "; started " + wezGuiExe + " from PATH")
		return nil
	}
	s.say("terminal: no WezTerm (" + where + "; not on PATH); starting Windows Terminal: " + wtFallback)
	if err := s.start(wtFallback); err != nil {
		return fmt.Errorf("no terminal: %s not found (%s; PATH: %v), and %s: %w", wezGuiExe, where, pathErr, wtFallback, err)
	}
	return nil
}

func (s *termStarter) say(line string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if line != s.said {
		s.said = line
		s.log(line)
	}
}
