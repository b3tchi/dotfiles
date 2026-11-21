// soloist installer (the dotfiles' soloist dot, `go run .`): fetch Spotify Soloist (the official headless Connect player)
// and, on a musl system (postmarketOS, Alpine), the glibc libraries it needs.
//
// usage: go run . [--dest DIR] [--force] [--max-age DAYS]
//
//	--dest     install dir (default ~/.local/lib/soloist)
//	--force    download the build and the libraries again
//	--max-age  refresh the build when the copy is older than this (default 30;
//	           Spotify's builds stop working 90 days after they were built)
//
// Result in DEST:
//
//	soloist      the program, from https://soloist-builds.spotifycdn.com
//	lib/         musl systems only: glibc loader + the shared libraries soloist
//	             and libpulse need, from Debian trixie packages (the system
//	             Spotify tests on), fetched over HTTPS and checked against the
//	             SHA256 in Debian's package index. Only the DT_NEEDED closure
//	             is kept (about 14 MB). Unpacking .deb data needs xz (or zstd).
//	soloist-run  wrapper: runs soloist through lib/'s loader, or directly on a
//	             glibc system. Use it like soloist itself (the dot links
//	             a `soloist` shim to it on PATH).
//
// Soloist is closed source; this only downloads Spotify's published build.
package main

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"debug/elf"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"
)

type arch struct{ build, debian, loader, triplet string }

var arches = map[string]arch{
	"arm64": {"arm64", "arm64", "ld-linux-aarch64.so.1", "aarch64-linux-gnu"},
	"amd64": {"x86_64", "amd64", "ld-linux-x86-64.so.2", "x86_64-linux-gnu"},
	"arm":   {"arm32", "armhf", "ld-linux-armhf.so.3", "arm-linux-gnueabihf"},
}

const (
	buildURL = "https://soloist-builds.spotifycdn.com/soloist_release_%s.tar.gz"
	debian   = "https://deb.debian.org/debian"
	suite    = "trixie"
)

var (
	rootPkgs = []string{"libc6", "libgcc-s1", "libatomic1", "libpulse0"}
	// loaded with dlopen, so not in soloist's DT_NEEDED: libpulse is its audio output
	dlopened = []string{"libpulse.so.0"}
)

func say(format string, a ...any) { fmt.Printf("soloist: "+format+"\n", a...) }

func main() {
	if err := run(os.Args[1:]); err != nil {
		say("ERROR -- %v", err) // one line for rotz output
		os.Exit(1)
	}
}

func run(args []string) error {
	home, _ := os.UserHomeDir()
	dest := filepath.Join(home, ".local/lib/soloist")
	force, maxAge := false, 30.0
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "--dest" && i+1 < len(args):
			dest, _ = filepath.Abs(args[i+1])
			i++
		case a == "--max-age" && i+1 < len(args):
			v, err := strconv.ParseFloat(args[i+1], 64)
			if err != nil {
				return fmt.Errorf("--max-age %s: %v", args[i+1], err)
			}
			maxAge = v
			i++
		case a == "--force":
			force = true
		case a == "-h" || a == "--help":
			fmt.Println("usage: go run . [--dest DIR] [--force] [--max-age DAYS]")
			return nil
		default:
			return fmt.Errorf("unknown argument %s", a)
		}
	}
	ar, ok := arches[runtime.GOARCH]
	if !ok {
		return fmt.Errorf("no Soloist build for %s", runtime.GOARCH)
	}
	if err := os.MkdirAll(dest, 0o755); err != nil {
		return err
	}
	binary := filepath.Join(dest, "soloist")

	st, err := os.Stat(binary)
	age := -1.0
	if err == nil {
		age = time.Since(st.ModTime()).Hours() / 24
	}
	if force || age < 0 || age > maxAge {
		if err := fetchBuild(ar.build, binary); err != nil {
			return err
		}
	} else {
		say("build is %d days old, kept (refresh after %.0f; --force downloads now)", int(age), maxAge)
	}

	lib := filepath.Join(dest, "lib")
	var runLine string
	if systemGlibc(ar.loader) {
		os.RemoveAll(lib)
		runLine = `exec "$here/soloist" "$@"` + "\n"
	} else {
		if _, err := os.Stat(filepath.Join(lib, ar.loader)); force || err != nil {
			if err := buildLibs(ar, binary, dest); err != nil {
				return err
			}
		} else {
			say("glibc libraries present (--force fetches them again)")
		}
		runLine = fmt.Sprintf(`exec "$here/lib/%s" --library-path "$here/lib" "$here/soloist" "$@"`+"\n", ar.loader)
	}
	wrapper := filepath.Join(dest, "soloist-run")
	script := "#!/bin/sh\n# soloist through the glibc loader when the system has none (written by the dotfiles soloist dot)\n" +
		`here="$(cd "$(dirname "$0")" && pwd)"` + "\n" + runLine
	if err := os.WriteFile(wrapper+".new", []byte(script), 0o755); err != nil {
		return err
	}
	if err := os.Rename(wrapper+".new", wrapper); err != nil {
		return err
	}
	say("installed in %s", dest)
	return nil
}

func fetch(url string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", "soloist-install")
	c := &http.Client{Timeout: 5 * time.Minute}
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%s: HTTP %d", url, resp.StatusCode)
	}
	return io.ReadAll(resp.Body)
}

// fetchBuild: the soloist executable from Spotify's tarball, replaced
// atomically (a running soloist keeps its old inode).
func fetchBuild(build, binary string) error {
	say("downloading the %s build", build)
	blob, err := fetch(fmt.Sprintf(buildURL, build))
	if err != nil {
		return err
	}
	zr, err := gzip.NewReader(bytes.NewReader(blob))
	if err != nil {
		return err
	}
	tr := tar.NewReader(zr)
	found := false
	for {
		h, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return err
		}
		switch path.Clean(h.Name) {
		case "soloist":
			if h.Typeflag != tar.TypeReg {
				return errors.New("soloist in the tarball is not a regular file")
			}
			tmp := binary + ".new"
			f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
			if err != nil {
				return err
			}
			if _, err := io.Copy(f, tr); err != nil {
				f.Close()
				return err
			}
			f.Close()
			if err := os.Rename(tmp, binary); err != nil {
				return err
			}
			now := time.Now()
			os.Chtimes(binary, now, now)
			found = true
		case "CHANGELOG.md":
			sc := bufio.NewScanner(tr)
			for sc.Scan() {
				if l := sc.Text(); strings.HasPrefix(l, "## ") {
					say("%s", strings.TrimLeft(l, "# "))
					break
				}
			}
		}
	}
	if !found {
		return errors.New("no soloist in the tarball")
	}
	return nil
}

func systemGlibc(loader string) bool {
	for _, d := range []string{"/lib", "/lib64", "/usr/lib", "/usr/lib64"} {
		if _, err := os.Stat(filepath.Join(d, loader)); err == nil {
			return true
		}
	}
	return false
}

// ---- Debian packages ----

type pkg map[string]string

func debianIndex(a string) (map[string]pkg, map[string]string, error) {
	blob, err := fetch(fmt.Sprintf("%s/dists/%s/main/binary-%s/Packages.gz", debian, suite, a))
	if err != nil {
		return nil, nil, err
	}
	zr, err := gzip.NewReader(bytes.NewReader(blob))
	if err != nil {
		return nil, nil, err
	}
	raw, err := io.ReadAll(zr)
	if err != nil {
		return nil, nil, err
	}
	pkgs, provides := map[string]pkg{}, map[string]string{}
	for _, stanza := range strings.Split(string(raw), "\n\n") {
		f, key := pkg{}, ""
		for _, line := range strings.Split(stanza, "\n") {
			if (strings.HasPrefix(line, " ") || strings.HasPrefix(line, "\t")) && key != "" {
				f[key] += " " + strings.TrimSpace(line)
			} else if k, v, ok := strings.Cut(line, ":"); ok {
				key = k
				f[k] = strings.TrimSpace(v)
			}
		}
		name := f["Package"]
		if name == "" {
			continue
		}
		if _, seen := pkgs[name]; seen {
			continue
		}
		pkgs[name] = f
		for _, p := range strings.Split(f["Provides"], ",") {
			if fs := strings.Fields(p); len(fs) > 0 {
				if _, ok := provides[fs[0]]; !ok {
					provides[fs[0]] = name
				}
			}
		}
	}
	return pkgs, provides, nil
}

func depNames(field string) []string {
	var out []string
	for _, alt := range strings.Split(field, ",") {
		alt = strings.TrimSpace(alt)
		if alt == "" {
			continue
		}
		first := strings.TrimSpace(strings.Split(alt, "|")[0]) // first alternative
		name := strings.Fields(first)[0]
		out = append(out, strings.Split(name, ":")[0])
	}
	return out
}

func resolve(pkgs map[string]pkg, provides map[string]string, roots []string) []string {
	var seen []string
	have := map[string]bool{}
	todo := append([]string{}, roots...)
	for len(todo) > 0 {
		n := todo[len(todo)-1]
		todo = todo[:len(todo)-1]
		if _, ok := pkgs[n]; !ok {
			if p, ok := provides[n]; ok {
				n = p
			}
		}
		if have[n] {
			continue
		}
		f, ok := pkgs[n]
		if !ok {
			say("WARNING -- %s not in the Debian index, skipped", n)
			continue
		}
		have[n] = true
		seen = append(seen, n)
		todo = append(todo, depNames(f["Depends"])...)
		todo = append(todo, depNames(f["Pre-Depends"])...)
	}
	return seen
}

// debData: the data.tar member of a .deb (ar archive), decompressed.
func debData(blob []byte) (*tar.Reader, error) {
	if !bytes.HasPrefix(blob, []byte("!<arch>\n")) {
		return nil, errors.New("not a .deb")
	}
	pos := 8
	for pos+60 <= len(blob) {
		hdr := blob[pos : pos+60]
		name := strings.TrimRight(strings.TrimSpace(string(hdr[:16])), "/")
		size, err := strconv.Atoi(strings.TrimSpace(string(hdr[48:58])))
		if err != nil {
			return nil, err
		}
		body := blob[pos+60 : pos+60+size]
		if strings.HasPrefix(name, "data.tar") {
			var data []byte
			switch {
			case strings.HasSuffix(name, ".xz"):
				data, err = filter(body, "xz", "-dc")
			case strings.HasSuffix(name, ".zst"):
				data, err = filter(body, "zstd", "-dc")
			case strings.HasSuffix(name, ".gz"):
				var zr *gzip.Reader
				if zr, err = gzip.NewReader(bytes.NewReader(body)); err == nil {
					data, err = io.ReadAll(zr)
				}
			default:
				data = body
			}
			if err != nil {
				return nil, fmt.Errorf("%s: %v", name, err)
			}
			return tar.NewReader(bytes.NewReader(data)), nil
		}
		pos += 60 + size + size&1
	}
	return nil, errors.New("no data.tar in .deb")
}

func filter(in []byte, prog string, args ...string) ([]byte, error) {
	if _, err := exec.LookPath(prog); err != nil {
		return nil, fmt.Errorf("%s needed to unpack Debian packages", prog)
	}
	cmd := exec.Command(prog, args...)
	cmd.Stdin = bytes.NewReader(in)
	var out, errb bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errb
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("%s: %v %s", prog, err, strings.TrimSpace(errb.String()))
	}
	return out.Bytes(), nil
}

func needed(p string) []string {
	f, err := elf.Open(p)
	if err != nil {
		return nil
	}
	defer f.Close()
	libs, _ := f.ImportedLibraries()
	return libs
}

func buildLibs(ar arch, binary, dest string) error {
	say("glibc libraries from Debian %s/%s", suite, ar.debian)
	pkgs, provides, err := debianIndex(ar.debian)
	if err != nil {
		return err
	}
	names := resolve(pkgs, provides, rootPkgs)
	stage, err := os.MkdirTemp("", "soloist-libs.")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	libDir := "/lib/" + ar.triplet + "/"
	for _, n := range names {
		f := pkgs[n]
		blob, err := fetch(debian + "/" + f["Filename"])
		if err != nil {
			return err
		}
		sum := sha256.Sum256(blob)
		if hex.EncodeToString(sum[:]) != f["SHA256"] {
			return fmt.Errorf("%s: SHA256 does not match the Debian index", f["Filename"])
		}
		tr, err := debData(blob)
		if err != nil {
			return fmt.Errorf("%s: %v", n, err)
		}
		for {
			h, err := tr.Next()
			if err == io.EOF {
				break
			}
			if err != nil {
				return err
			}
			base := path.Base(h.Name)
			if !strings.Contains(base, ".so") || !strings.Contains(h.Name, libDir) {
				continue
			}
			target := filepath.Join(stage, base)
			switch h.Typeflag {
			case tar.TypeSymlink:
				if _, err := os.Lstat(target); err != nil {
					os.Symlink(path.Base(h.Linkname), target)
				}
			case tar.TypeReg:
				out, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o755)
				if err != nil {
					return err
				}
				_, err = io.Copy(out, tr)
				out.Close()
				if err != nil {
					return err
				}
			}
		}
	}
	// keep only what soloist (+ dlopen'd libpulse) needs
	keep := map[string]bool{}
	todo := append(append(needed(binary), dlopened...), ar.loader)
	for len(todo) > 0 {
		n := todo[len(todo)-1]
		todo = todo[:len(todo)-1]
		if keep[n] {
			continue
		}
		p := filepath.Join(stage, n)
		real, err := filepath.EvalSymlinks(p)
		if err != nil {
			return fmt.Errorf("library %s not found in the Debian packages", n)
		}
		keep[n] = true
		todo = append(todo, needed(real)...)
	}
	newDir := dest + ".lib.new"
	os.RemoveAll(newDir)
	if err := os.MkdirAll(newDir, 0o755); err != nil {
		return err
	}
	var kept []string
	var size int64
	for n := range keep {
		kept = append(kept, n)
	}
	sort.Strings(kept)
	for _, n := range kept {
		real, _ := filepath.EvalSymlinks(filepath.Join(stage, n))
		b, err := os.ReadFile(real)
		if err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(newDir, n), b, 0o755); err != nil {
			return err
		}
		size += int64(len(b))
	}
	sort.Strings(names)
	src := fmt.Sprintf("debian %s %s: %s\n", suite, ar.debian, strings.Join(names, " "))
	if err := os.WriteFile(filepath.Join(newDir, ".source"), []byte(src), 0o644); err != nil {
		return err
	}
	old := filepath.Join(dest, "lib")
	os.RemoveAll(old)
	if err := os.Rename(newDir, old); err != nil {
		return err
	}
	say("%d libraries, %.1f MB in %s", len(kept), float64(size)/1e6, old)
	return nil
}
