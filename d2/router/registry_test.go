package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadRegistry(t *testing.T) {
	tests := []struct {
		name      string
		yaml      string
		wantNames []string // local project names expected
		wantSkip  []string // ssh-excluded names expected absent
		wantErr   bool
	}{
		{
			name: "local entry included",
			yaml: `projects:
  dotfiles:
    path: /home/jan/.dotfiles
`,
			wantNames: []string{"dotfiles"},
		},
		{
			name: "ssh entry excluded",
			yaml: `projects:
  remote:
    path: /home/user/repos/remote
    ssh: workstation
`,
			wantSkip: []string{"remote"},
		},
		{
			name: "ssh empty string normalised to local",
			yaml: `projects:
  localish:
    path: /home/jan/repos/localish
    ssh: ""
`,
			wantNames: []string{"localish"},
		},
		{
			name: "ssh null normalised to local",
			yaml: `projects:
  nullish:
    path: /home/jan/repos/nullish
    ssh:
`,
			wantNames: []string{"nullish"},
		},
		{
			name: "mixed local and ssh",
			yaml: `projects:
  local1:
    path: /home/jan/repos/local1
  remote1:
    path: /home/user/repos/remote1
    ssh: ws1
  local2:
    path: /home/jan/repos/local2
    ssh: ""
`,
			wantNames: []string{"local1", "local2"},
			wantSkip:  []string{"remote1"},
		},
		{
			name: "empty projects map",
			yaml: `projects: {}
`,
			wantNames: []string{},
		},
		{
			name: "only ssh entries — empty local set, no crash",
			yaml: `projects:
  r1:
    path: /home/user/repos/r1
    ssh: ws
  r2:
    path: /home/user/repos/r2
    ssh: ws2
`,
			wantNames: []string{},
			wantSkip:  []string{"r1", "r2"},
		},
		{
			name:    "malformed yaml errors",
			yaml:    `projects: {bad yaml: [unclosed`,
			wantErr: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			f, err := os.CreateTemp(t.TempDir(), "projects-*.yaml")
			if err != nil {
				t.Fatal(err)
			}
			if _, err := f.WriteString(tc.yaml); err != nil {
				t.Fatal(err)
			}
			f.Close()

			reg, err := loadRegistry(f.Name())
			if tc.wantErr {
				if err == nil {
					t.Error("expected error but got nil")
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			for _, name := range tc.wantNames {
				if _, ok := reg[name]; !ok {
					t.Errorf("expected local project %q in registry, not found", name)
				}
			}
			for _, name := range tc.wantSkip {
				if _, ok := reg[name]; ok {
					t.Errorf("expected ssh project %q to be excluded, but found in registry", name)
				}
			}
		})
	}
}

func TestLoadRegistryMissingFile(t *testing.T) {
	reg, err := loadRegistry("/nonexistent/path/projects.yaml")
	if err == nil {
		t.Error("expected error for missing file")
	}
	if reg != nil {
		t.Error("expected nil registry for missing file")
	}
}

func TestWalkProjectD2Files(t *testing.T) {
	// Use the checked-in fixture walk tree:
	// fixtures/walk/
	//   alpha.d2
	//   bravo.d2
	//   sub/
	//     alpha.d2       <- duplicate basename "alpha.d2"
	//     charlie.d2
	//     deep/
	//       delta.d2
	//   .hidden/
	//     secret.d2      <- dot-dir, must be skipped
	//   not-a-diagram.txt <- non-.d2, must be skipped

	fixtureDir, err := filepath.Abs(filepath.Join("fixtures", "walk"))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(fixtureDir); os.IsNotExist(err) {
		t.Skipf("fixture dir %s not found — run from d2/router", fixtureDir)
	}

	routes, collisions := walkProjectFiles("testproject", fixtureDir)

	// Expected routes (first lexical path wins for duplicates)
	// alpha.d2 appears at: fixtures/walk/alpha.d2 and fixtures/walk/sub/alpha.d2
	// Lexical sort: fixtures/walk/alpha.d2 < fixtures/walk/sub/alpha.d2 → first wins
	expected := map[string]bool{
		"/testproject/alpha.d2":   true,
		"/testproject/bravo.d2":   true,
		"/testproject/charlie.d2": true,
		"/testproject/delta.d2":   true,
	}

	for route := range expected {
		if _, ok := routes[route]; !ok {
			t.Errorf("expected route %q not found in result", route)
		}
	}

	// secret.d2 in .hidden/ must be absent
	for route := range routes {
		if strings.Contains(route, "secret") {
			t.Errorf("dot-dir file leaked into routes: %q", route)
		}
		if strings.Contains(route, "not-a-diagram") {
			t.Errorf("non-.d2 file leaked into routes: %q", route)
		}
	}

	// alpha.d2 appears twice → collision flag
	if !collisions["alpha.d2"] {
		t.Error("expected collision flag for alpha.d2 (duplicate basename), not set")
	}
	// bravo, charlie, delta are unique — no collision
	for _, name := range []string{"bravo.d2", "charlie.d2", "delta.d2"} {
		if collisions[name] {
			t.Errorf("unexpected collision flag for %q", name)
		}
	}
}

func TestBuildIndex(t *testing.T) {
	reg := Registry{
		"proj-a": "/some/path/a",
		"proj-b": "/some/path/b",
	}

	// Use temp dirs that exist but are empty (no .d2 files)
	tmpA := t.TempDir()
	tmpB := t.TempDir()
	reg["proj-a"] = tmpA
	reg["proj-b"] = tmpB

	// Add one .d2 file in proj-a
	if err := os.WriteFile(filepath.Join(tmpA, "diagram.d2"), []byte("x -> y"), 0644); err != nil {
		t.Fatal(err)
	}
	// proj-b stays empty

	idx := buildIndex(reg)

	found := false
	for _, e := range idx.Entries {
		if e.Route == "/proj-a/diagram.d2" {
			found = true
		}
	}
	if !found {
		t.Error("expected /proj-a/diagram.d2 in index entries")
	}

	// proj-b should be present with 0 entries (not crashed)
	if idx == nil {
		t.Fatal("buildIndex returned nil")
	}
}
