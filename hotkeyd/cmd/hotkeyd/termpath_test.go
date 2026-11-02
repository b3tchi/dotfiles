package main

// kwi3-wv1u: $mod+Return on Windows runs `wezterm-gui.exe start`, resolved
// to scoop's WezTerm (%SCOOP%, else %USERPROFILE%\scoop), then PATH, and
// falls back to Windows Terminal (`wt.exe -w new`) when there is no
// WezTerm at all. Portable: the file system is a map, as in
// kwi3runpath_test.go.

import (
	"errors"
	"strings"
	"testing"
)

const up = `C:\Users\j`

func scoopWez(root string) fakeRunFS {
	return fakeRunFS{root + `\apps\wezterm\current\wezterm-gui.exe`: "MZ"}
}

// termStarterOver builds a termStarter whose start fails for every command
// whose program word is in missing.
func termStarterOver(f fakeRunFS, env map[string]string, missing ...string) (*termStarter, *[]string, *[]string) {
	var started, logged []string
	s := &termStarter{
		start: func(cmd string) error {
			for _, m := range missing {
				if strings.HasPrefix(cmd, m+" ") || cmd == m {
					return errors.New("exec: " + m + ": executable file not found in %PATH%")
				}
			}
			started = append(started, cmd)
			return nil
		},
		getenv: func(k string) string { return env[k] },
		fs:     f.fs(),
		log:    func(l string) { logged = append(logged, l) },
	}
	return s, &started, &logged
}

func TestTermStarter_ScoopUnderUserProfile(t *testing.T) {
	s, started, logged := termStarterOver(scoopWez(up+`\scoop`), map[string]string{"USERPROFILE": up})
	for i := 0; i < 2; i++ {
		if err := s.Run("wezterm-gui.exe start"); err != nil {
			t.Fatal(err)
		}
	}
	want := `"` + up + `\scoop\apps\wezterm\current\wezterm-gui.exe" start`
	if strings.Join(*started, "|") != want+"|"+want {
		t.Fatalf("started %q, want %q twice", *started, want)
	}
	if len(*logged) != 1 || !strings.Contains((*logged)[0], `\scoop\apps\wezterm\current\wezterm-gui.exe`) {
		t.Fatalf("logged %q, want one line naming the exe", *logged)
	}
}

func TestTermStarter_ScoopEnvWins(t *testing.T) {
	f := scoopWez(`D:\scoop`)
	for k, v := range scoopWez(up + `\scoop`) {
		f[k] = v
	}
	s, started, _ := termStarterOver(f, map[string]string{"USERPROFILE": up, "SCOOP": `D:\scoop\`})
	_ = s.Run("wezterm-gui.exe start")
	if len(*started) != 1 || !strings.HasPrefix((*started)[0], `"D:\scoop\apps\wezterm\current\wezterm-gui.exe"`) {
		t.Fatalf("started %q, want %%SCOOP%%'s WezTerm", *started)
	}
}

func TestTermStarter_PathWhenNoScoop(t *testing.T) {
	s, started, logged := termStarterOver(fakeRunFS{}, map[string]string{"USERPROFILE": up})
	_ = s.Run("wezterm-gui.exe start")
	if strings.Join(*started, "|") != "wezterm-gui.exe start" {
		t.Fatalf("started %q, want the PATH lookup", *started)
	}
	if len(*logged) != 1 || !strings.Contains((*logged)[0], "PATH") {
		t.Fatalf("logged %q", *logged)
	}
}

func TestTermStarter_FallsBackToWindowsTerminal(t *testing.T) {
	s, started, logged := termStarterOver(fakeRunFS{}, map[string]string{"USERPROFILE": up}, "wezterm-gui.exe")
	for i := 0; i < 2; i++ {
		if err := s.Run("wezterm-gui.exe start"); err != nil {
			t.Fatal(err)
		}
	}
	if strings.Join(*started, "|") != "wt.exe -w new|wt.exe -w new" {
		t.Fatalf("started %q, want Windows Terminal twice", *started)
	}
	if len(*logged) != 1 || !strings.Contains((*logged)[0], "wt.exe -w new") ||
		!strings.Contains((*logged)[0], `\scoop\apps\wezterm\current\wezterm-gui.exe`) {
		t.Fatalf("logged %q, want one line naming where WezTerm was looked for and the fallback", *logged)
	}
}

func TestTermStarter_NeitherNamesBoth(t *testing.T) {
	s, started, _ := termStarterOver(fakeRunFS{}, map[string]string{"USERPROFILE": up}, "wezterm-gui.exe", "wt.exe")
	err := s.Run("wezterm-gui.exe start")
	if err == nil || len(*started) != 0 {
		t.Fatalf("err %v started %q", err, *started)
	}
	for _, w := range []string{"wezterm-gui.exe", "wt.exe", "not found"} {
		if !strings.Contains(err.Error(), w) {
			t.Fatalf("error %q does not name %q", err, w)
		}
	}
}

// A WezTerm that IS found but will not start is reported, not papered
// over with Windows Terminal.
func TestTermStarter_FoundButFailingIsAnError(t *testing.T) {
	s, _, _ := termStarterOver(scoopWez(up+`\scoop`), map[string]string{"USERPROFILE": up}, `"`+up+`\scoop\apps\wezterm\current\wezterm-gui.exe"`)
	if err := s.Run("wezterm-gui.exe start"); err == nil {
		t.Fatal("no error")
	}
}

func TestTermStarter_OtherCommandsUntouched(t *testing.T) {
	s, started, logged := termStarterOver(scoopWez(up+`\scoop`), map[string]string{"USERPROFILE": up})
	for _, c := range []string{"kwi3-run.exe launcher", "wt.exe -w new", "wezterm-gui.exe2 x", `"wezterm-gui.exe" start`} {
		_ = s.Run(c)
	}
	if strings.Join(*started, "|") != `kwi3-run.exe launcher|wt.exe -w new|wezterm-gui.exe2 x|"wezterm-gui.exe" start` || len(*logged) != 0 {
		t.Fatalf("started %q logged %q", *started, *logged)
	}
}
