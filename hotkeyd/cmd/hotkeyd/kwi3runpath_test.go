package main

// A Run of kwi3-run.exe starts the runner beside hotkeyd.exe (kwi3's
// scoop package, kwi3-etpz), and falls back to the PATH lookup only when
// there is none; the retired %LOCALAPPDATA%\kwi3\run\current.txt deploy
// is never read (kwi3-dfnb). Portable: the file system is a map, so these
// run untagged on Linux too.

import (
	"errors"
	"io/fs"
	"strings"
	"testing"
	"time"
)

// fakeRunFS is a Windows file tree as a map: a path ending in a file's
// contents, or isDir for a directory. Paths are compared exactly.
type fakeRunFS map[string]string

const isDir = "\x00dir"

func (f fakeRunFS) fs() runFS {
	return runFS{
		Stat: func(p string) (fs.FileInfo, error) {
			v, ok := f[p]
			if !ok {
				return nil, fs.ErrNotExist
			}
			return fakeInfo{dir: v == isDir}, nil
		},
	}
}

type fakeInfo struct{ dir bool }

func (i fakeInfo) Name() string       { return "" }
func (i fakeInfo) Size() int64        { return 0 }
func (i fakeInfo) Mode() fs.FileMode  { return map[bool]fs.FileMode{true: fs.ModeDir}[i.dir] }
func (i fakeInfo) ModTime() time.Time { return time.Time{} }
func (i fakeInfo) IsDir() bool        { return i.dir }
func (i fakeInfo) Sys() any           { return nil }

const pkg = `C:\Users\j\scoop\apps\kwi3\0.3.0`

// packaged is kwi3's package directory with hotkeyd.exe and, when
// runner, kwi3-run.exe beside it.
func packaged(runner bool) fakeRunFS {
	f := fakeRunFS{pkg: isDir, pkg + `\hotkeyd.exe`: "MZ"}
	if runner {
		f[pkg+`\kwi3-run.exe`] = "MZ"
	}
	return f
}

// starter builds a kwi3RunStarter over f, running as self, with a
// recorded start and log.
func starter(f fakeRunFS, self string, startErr error) (*kwi3RunStarter, *[]string, *[]string) {
	var started, logged []string
	s := &kwi3RunStarter{
		start: func(cmd string) error {
			started = append(started, cmd)
			return startErr
		},
		self: self,
		fs:   f.fs(),
		log:  func(l string) { logged = append(logged, l) },
	}
	return s, &started, &logged
}

func TestKwi3RunStarter_PackagedRunnerBesideHotkeyd(t *testing.T) {
	s, started, logged := starter(packaged(true), pkg+`\hotkeyd.exe`, nil)
	for _, verb := range []string{"launcher", "switcher", "switcher-confirm"} {
		if err := s.Run("kwi3-run.exe " + verb); err != nil {
			t.Fatal(err)
		}
	}
	exe := `"` + pkg + `\kwi3-run.exe"`
	want := []string{exe + " launcher", exe + " switcher", exe + " switcher-confirm"}
	if strings.Join(*started, "|") != strings.Join(want, "|") {
		t.Fatalf("started %q, want %q", *started, want)
	}
	if len(*logged) != 1 || !strings.Contains((*logged)[0], pkg+`\kwi3-run.exe`) ||
		!strings.Contains((*logged)[0], "beside") {
		t.Fatalf("logged %q, want one line naming the runner beside hotkeyd", *logged)
	}
}

// The retired deploy (%LOCALAPPDATA%\kwi3\run\current.txt and its v<N>)
// is never read: with no runner beside hotkeyd, PATH is next, even when
// an old deploy is still on disk.
func TestKwi3RunStarter_NoRunnerBesideFallsBackToPath(t *testing.T) {
	const lad = `C:\Users\j\AppData\Local`
	f := packaged(false)
	f[lad+`\kwi3\run\current.txt`] = lad + `\kwi3\run\v1` + "\r\n"
	f[lad+`\kwi3\run\v1`] = isDir
	f[lad+`\kwi3\run\v1\kwi3-run.exe`] = "MZ"
	s, started, logged := starter(f, pkg+`\hotkeyd.exe`, nil)
	_ = s.Run("kwi3-run.exe launcher")
	_ = s.Run("kwi3-run.exe switcher")
	if strings.Join(*started, "|") != "kwi3-run.exe launcher|kwi3-run.exe switcher" {
		t.Fatalf("started %q, want the bare PATH lookup", *started)
	}
	if len(*logged) != 1 || !strings.Contains((*logged)[0], "PATH") ||
		!strings.Contains((*logged)[0], pkg+`\kwi3-run.exe`) || strings.Contains((*logged)[0], "current.txt") {
		t.Fatalf("logged %q, want one line naming the missing runner beside hotkeyd and PATH", *logged)
	}
}

func TestKwi3RunStarter_DirectoryBesideIsNoRunner(t *testing.T) {
	f := packaged(false)
	f[pkg+`\kwi3-run.exe`] = isDir
	s, started, _ := starter(f, pkg+`\hotkeyd.exe`, nil)
	_ = s.Run("kwi3-run.exe launcher")
	if (*started)[0] != "kwi3-run.exe launcher" {
		t.Fatalf("started %q, want the PATH lookup", *started)
	}
}

func TestKwi3RunStarter_UnknownSelfUsesPath(t *testing.T) {
	s, started, logged := starter(packaged(true), "", nil)
	_ = s.Run("kwi3-run.exe launcher")
	if (*started)[0] != "kwi3-run.exe launcher" || !strings.Contains((*logged)[0], "unknown") {
		t.Fatalf("started %q logged %q, want PATH and a line saying hotkeyd's path is unknown", *started, *logged)
	}
}

func TestKwi3RunStarter_PathMissNamesBothPlaces(t *testing.T) {
	s, _, _ := starter(packaged(false), pkg+`\hotkeyd.exe`, errors.New("start kwi3-run.exe: executable file not found in %PATH%"))
	err := s.Run("kwi3-run.exe launcher")
	if err == nil {
		t.Fatal("no error")
	}
	for _, w := range []string{pkg + `\kwi3-run.exe`, "PATH", "not found"} {
		if !strings.Contains(err.Error(), w) {
			t.Fatalf("error %q does not name %q", err, w)
		}
	}
}

func TestKwi3RunStarter_OtherCommandsUntouched(t *testing.T) {
	s, started, logged := starter(packaged(true), pkg+`\hotkeyd.exe`, nil)
	for _, c := range []string{"wt.exe -w new", "kwi3-run.exe2 x", `"kwi3-run.exe" launcher`} {
		_ = s.Run(c)
	}
	if strings.Join(*started, "|") != `wt.exe -w new|kwi3-run.exe2 x|"kwi3-run.exe" launcher` || len(*logged) != 0 {
		t.Fatalf("started %q logged %q: only a bare kwi3-run.exe first word is resolved", *started, *logged)
	}
	// The bare program with no verb is still resolved.
	_ = s.Run("kwi3-run.exe")
	if (*started)[3] != `"`+pkg+`\kwi3-run.exe"` {
		t.Fatalf("started %q", (*started)[3])
	}
}
