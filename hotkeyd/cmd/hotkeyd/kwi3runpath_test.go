package main

// kwi3-hoex.27: a Run of kwi3-run.exe starts the DEPLOYED runner, the one
// %LOCALAPPDATA%\kwi3\run\current.txt names (kwi3's
// i3kwin/runner/win32/deploy.sh), read afresh on every start, and falls
// back to the PATH lookup only when there is none. Portable: the file
// system is a map, so these run untagged on Linux too.

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
		ReadFile: func(p string) ([]byte, error) {
			v, ok := f[p]
			if !ok {
				return nil, fs.ErrNotExist
			}
			if v == isDir {
				return nil, errors.New("is a directory")
			}
			return []byte(v), nil
		},
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

const lad = `C:\Users\j\AppData\Local`

func deployed(current string, versions ...string) fakeRunFS {
	f := fakeRunFS{lad + `\kwi3\run\current.txt`: current}
	for _, v := range versions {
		f[lad+`\kwi3\run\`+v] = isDir
		f[lad+`\kwi3\run\`+v+`\kwi3-run.exe`] = "MZ"
	}
	return f
}

func TestResolveKwi3Run(t *testing.T) {
	exe1 := lad + `\kwi3\run\v1\kwi3-run.exe`
	cases := []struct {
		name   string
		lad    string
		fs     fakeRunFS
		want   string
		whyHas string
	}{
		// What deploy.sh writes: the absolute v<N> directory, CRLF.
		{"absolute CRLF", lad, deployed(lad+`\kwi3\run\v1`+"\r\n", "v1"), exe1, ""},
		{"BOM, spaces, trailing backslash", lad,
			deployed("\ufeff  "+lad+`\kwi3\run\v1\`+" \t\r\n", "v1"), exe1, ""},
		{"LF, more lines ignored", lad,
			deployed(lad+`\kwi3\run\v1`+"\nv2\n", "v1", "v2"), exe1, ""},
		{"relative name", lad, deployed("v1\r\n", "v1"), exe1, ""},
		{"no LOCALAPPDATA", "", deployed("v1\r\n", "v1"), "", "%LOCALAPPDATA% is unset"},
		{"no current.txt", lad, fakeRunFS{}, "", `no ` + lad + `\kwi3\run\current.txt`},
		{"current.txt unreadable", lad, fakeRunFS{lad + `\kwi3\run\current.txt`: isDir}, "",
			"cannot read " + lad + `\kwi3\run\current.txt`},
		{"empty", lad, deployed("\r\n"), "", "is empty"},
		{"BOM only", lad, deployed("\ufeff"), "", "is empty"},
		{"dir missing", lad, deployed(lad + `\kwi3\run\v9` + "\r\n"), "",
			`names ` + lad + `\kwi3\run\v9, which is not a directory`},
		{"exe missing", lad, fakeRunFS{
			lad + `\kwi3\run\current.txt`: "v1\r\n",
			lad + `\kwi3\run\v1`:          isDir,
		}, "", `no ` + exe1},
		{"exe is a directory", lad, fakeRunFS{
			lad + `\kwi3\run\current.txt`: "v1\r\n",
			lad + `\kwi3\run\v1`:          isDir,
			exe1:                          isDir,
		}, "", `no ` + exe1},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got, why := resolveKwi3Run(c.lad, c.fs.fs())
			if got != c.want {
				t.Fatalf("path = %q (why %q), want %q", got, why, c.want)
			}
			if c.want != "" && why != "" {
				t.Fatalf("resolved, but why = %q", why)
			}
			if c.want == "" && !strings.Contains(why, c.whyHas) {
				t.Fatalf("why = %q, want it to contain %q", why, c.whyHas)
			}
		})
	}
}

// starter builds a kwi3RunStarter over f with a recorded start and log.
func starter(f fakeRunFS, env map[string]string, startErr error) (*kwi3RunStarter, *[]string, *[]string) {
	var started, logged []string
	s := &kwi3RunStarter{
		start: func(cmd string) error {
			started = append(started, cmd)
			return startErr
		},
		getenv: func(k string) string { return env[k] },
		fs:     f.fs(),
		log:    func(l string) { logged = append(logged, l) },
	}
	return s, &started, &logged
}

func TestKwi3RunStarter_StartsDeployedCopyAndSaysOnce(t *testing.T) {
	f := deployed(lad+`\kwi3\run\v1`+"\r\n", "v1")
	s, started, logged := starter(f, map[string]string{"LOCALAPPDATA": lad}, nil)
	for _, verb := range []string{"launcher", "switcher", "switcher-confirm"} {
		if err := s.Run("kwi3-run.exe " + verb); err != nil {
			t.Fatal(err)
		}
	}
	exe := `"` + lad + `\kwi3\run\v1\kwi3-run.exe"`
	want := []string{exe + " launcher", exe + " switcher", exe + " switcher-confirm"}
	if strings.Join(*started, "|") != strings.Join(want, "|") {
		t.Fatalf("started %q, want %q", *started, want)
	}
	if len(*logged) != 1 || !strings.Contains((*logged)[0], lad+`\kwi3\run\v1\kwi3-run.exe`) {
		t.Fatalf("logged %q, want one line naming the deployed exe", *logged)
	}
}

func TestKwi3RunStarter_RedeployIsPickedUp(t *testing.T) {
	f := deployed(lad+`\kwi3\run\v1`+"\r\n", "v1", "v2")
	s, started, logged := starter(f, map[string]string{"LOCALAPPDATA": lad}, nil)
	_ = s.Run("kwi3-run.exe launcher")
	f[lad+`\kwi3\run\current.txt`] = lad + `\kwi3\run\v2` + "\r\n"
	_ = s.Run("kwi3-run.exe launcher")
	_ = s.Run("kwi3-run.exe launcher")
	if !strings.Contains((*started)[0], `\v1\kwi3-run.exe"`) || !strings.Contains((*started)[1], `\v2\kwi3-run.exe"`) ||
		(*started)[2] != (*started)[1] {
		t.Fatalf("started %q: want v1 then v2 twice", *started)
	}
	if len(*logged) != 2 || !strings.Contains((*logged)[1], `\v2\kwi3-run.exe`) {
		t.Fatalf("logged %q: want one line per outcome (v1, then v2)", *logged)
	}
}

func TestKwi3RunStarter_FallsBackToPath(t *testing.T) {
	s, started, logged := starter(fakeRunFS{}, map[string]string{"LOCALAPPDATA": lad}, nil)
	_ = s.Run("kwi3-run.exe launcher")
	_ = s.Run("kwi3-run.exe switcher")
	if strings.Join(*started, "|") != "kwi3-run.exe launcher|kwi3-run.exe switcher" {
		t.Fatalf("started %q, want the bare PATH lookup", *started)
	}
	if len(*logged) != 1 || !strings.Contains((*logged)[0], "PATH") ||
		!strings.Contains((*logged)[0], `current.txt`) {
		t.Fatalf("logged %q, want one line saying why it fell back to PATH", *logged)
	}
}

func TestKwi3RunStarter_PathMissNamesBothPlaces(t *testing.T) {
	s, _, _ := starter(fakeRunFS{}, map[string]string{"LOCALAPPDATA": lad}, errors.New("start kwi3-run.exe: executable file not found in %PATH%"))
	err := s.Run("kwi3-run.exe launcher")
	if err == nil {
		t.Fatal("no error")
	}
	for _, w := range []string{lad + `\kwi3\run\current.txt`, "PATH", "not found"} {
		if !strings.Contains(err.Error(), w) {
			t.Fatalf("error %q does not name %q", err, w)
		}
	}
}

func TestKwi3RunStarter_OtherCommandsUntouched(t *testing.T) {
	f := deployed("v1\r\n", "v1")
	s, started, logged := starter(f, map[string]string{"LOCALAPPDATA": lad}, nil)
	for _, c := range []string{"wt.exe -w new", "kwi3-run.exe2 x", `"kwi3-run.exe" launcher`} {
		_ = s.Run(c)
	}
	if strings.Join(*started, "|") != `wt.exe -w new|kwi3-run.exe2 x|"kwi3-run.exe" launcher` || len(*logged) != 0 {
		t.Fatalf("started %q logged %q: only a bare kwi3-run.exe first word is resolved", *started, *logged)
	}
	// The bare program with no verb is still resolved.
	_ = s.Run("kwi3-run.exe")
	if (*started)[3] != `"`+lad+`\kwi3\run\v1\kwi3-run.exe"` {
		t.Fatalf("started %q", (*started)[3])
	}
}
