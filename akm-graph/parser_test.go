package main

import (
	"os"
	"path/filepath"
	"reflect"
	"sort"
	"testing"
)

// TestExtractWikilinks covers plain, piped, anchor, multiple, code-fence,
// and malformed cases.
func TestExtractWikilinks(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  []string
	}{
		{
			name:  "plain",
			input: "See [[us001]] for details.",
			want:  []string{"us001"},
		},
		{
			name:  "piped label",
			input: "See [[us001|the story]] for details.",
			want:  []string{"us001"},
		},
		{
			name:  "section anchor",
			input: "Refer to [[sp006#plan]] section.",
			want:  []string{"sp006"},
		},
		{
			name:  "section anchor with label",
			input: "See [[sp006#plan|the plan]] here.",
			want:  []string{"sp006"},
		},
		{
			name:  "multiple on same line",
			input: "Links: [[us001]] and [[sp002]] and [[ft003]].",
			want:  []string{"us001", "sp002", "ft003"},
		},
		{
			name:  "inside code fence — counted (known limitation)",
			input: "```\n[[us001]]\n```",
			want:  []string{"us001"},
		},
		{
			name:  "malformed — no close bracket",
			input: "Bad [[ link without close.",
			want:  []string{},
		},
		{
			name:  "empty inner content",
			input: "Empty [[]] here.",
			want:  []string{},
		},
		{
			name:  "unicode alias",
			input: "See [[日本語-note|日本語]] here.",
			want:  []string{"日本語-note"},
		},
		{
			name:  "multiple with anchors and labels",
			input: "[[adr0001|ADR1]] binds [[adr0002#decision]].",
			want:  []string{"adr0001", "adr0002"},
		},
		{
			name:  "no links",
			input: "Plain paragraph with no wikilinks.",
			want:  []string{},
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := extractWikilinks(tc.input)
			if got == nil {
				got = []string{}
			}
			if !reflect.DeepEqual(got, tc.want) {
				t.Errorf("extractWikilinks(%q)\n  got:  %v\n  want: %v", tc.input, got, tc.want)
			}
		})
	}
}

// TestParseFrontmatter covers full, missing aliases, missing status, and no
// frontmatter at all.
func TestParseFrontmatter(t *testing.T) {
	tests := []struct {
		name       string
		content    string
		wantFM     frontmatter
		wantBodyHas string
	}{
		{
			name: "full frontmatter",
			content: `---
aliases:
  - visualize-note-relations
status: ready
---

# Body text [[link1]]
`,
			wantFM: frontmatter{
				Aliases: []string{"visualize-note-relations"},
				Status:  "ready",
			},
			wantBodyHas: "Body text",
		},
		{
			name: "missing aliases",
			content: `---
status: done
---

Body`,
			wantFM:      frontmatter{Status: "done"},
			wantBodyHas: "Body",
		},
		{
			name: "missing status",
			content: `---
aliases:
  - some-alias
---

Body`,
			wantFM:      frontmatter{Aliases: []string{"some-alias"}},
			wantBodyHas: "Body",
		},
		{
			name:        "no frontmatter at all",
			content:     "# Just a heading\n\n[[link1]]",
			wantFM:      frontmatter{},
			wantBodyHas: "Just a heading",
		},
		{
			name: "multiple aliases — first is canonical",
			content: `---
aliases:
  - first-alias
  - second-alias
status: proposed
---
body`,
			wantFM: frontmatter{
				Aliases: []string{"first-alias", "second-alias"},
				Status:  "proposed",
			},
			wantBodyHas: "body",
		},
		{
			name: "empty aliases list",
			content: `---
aliases: []
status: ready
---
body`,
			wantFM:      frontmatter{Aliases: []string{}, Status: "ready"},
			wantBodyHas: "body",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			fm, body := parseFrontmatter([]byte(tc.content))
			if !reflect.DeepEqual(fm, tc.wantFM) {
				t.Errorf("parseFrontmatter fm\n  got:  %+v\n  want: %+v", fm, tc.wantFM)
			}
			if tc.wantBodyHas != "" {
				if !contains(string(body), tc.wantBodyHas) {
					t.Errorf("body does not contain %q: %q", tc.wantBodyHas, string(body))
				}
			}
		})
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(s) > 0 && containsHelper(s, sub))
}

func containsHelper(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}

// TestNodeTypeFromID covers the typed prefix → type mapping and hub/fallback.
func TestNodeTypeFromID(t *testing.T) {
	tests := []struct {
		id    string
		isHub bool
		want  string
	}{
		{"us006", false, "us"},
		{"sp001", false, "sp"},
		{"im004", false, "im"},
		{"ft002", false, "ft"},
		{"adr0001", false, "adr"},
		{"cat001", false, "cat"},
		{"pn001", false, "pn"},
		{"poc003", false, "poc"},
		{"board", true, "hub"},
		{"product", true, "hub"},
		{"random-note", false, "note"},
		{"daily-2026-06-12", false, "note"}, // daily prefix not in type list
		// edge: prefix matches but no digit after
		{"uspending", false, "note"},
		{"spaced", false, "note"},
	}
	for _, tc := range tests {
		t.Run(tc.id, func(t *testing.T) {
			got := nodeTypeFromID(tc.id, tc.isHub)
			if got != tc.want {
				t.Errorf("nodeTypeFromID(%q, %v) = %q, want %q", tc.id, tc.isHub, got, tc.want)
			}
		})
	}
}

// TestParseNote_EdgeCases verifies parseNote behaviour on edge-case files.
func TestParseNote_EdgeCases(t *testing.T) {
	dir := t.TempDir()

	// Note with no frontmatter
	noFM := filepath.Join(dir, "note001.md")
	if err := os.WriteFile(noFM, []byte("# Just a heading\n\n[[sp001]] [[us002]]\n"), 0644); err != nil {
		t.Fatal(err)
	}
	n, err := parseNote(noFM)
	if err != nil {
		t.Fatalf("parseNote no-fm: %v", err)
	}
	if n.ID != "note001" {
		t.Errorf("ID: got %q, want %q", n.ID, "note001")
	}
	if len(n.FM.Aliases) != 0 {
		t.Errorf("expected no aliases, got %v", n.FM.Aliases)
	}
	wantLinks := []string{"sp001", "us002"}
	sort.Strings(n.Links)
	if !reflect.DeepEqual(n.Links, wantLinks) {
		t.Errorf("links: got %v, want %v", n.Links, wantLinks)
	}

	// Empty file (no crash)
	empty := filepath.Join(dir, "empty001.md")
	if err := os.WriteFile(empty, []byte(""), 0644); err != nil {
		t.Fatal(err)
	}
	n2, err := parseNote(empty)
	if err != nil {
		t.Fatalf("parseNote empty: %v", err)
	}
	if n2.ID != "empty001" {
		t.Errorf("ID: got %q", n2.ID)
	}
	if len(n2.Links) != 0 {
		t.Errorf("expected no links on empty file, got %v", n2.Links)
	}
}

// TestWalkNotes_Empty verifies that an empty docs/notes dir returns no notes
// (but no crash), and hub files that are absent are also skipped.
func TestWalkNotes_Empty(t *testing.T) {
	root := t.TempDir()
	// Create docs/notes dir but put nothing in it.
	if err := os.MkdirAll(filepath.Join(root, "docs", "notes"), 0755); err != nil {
		t.Fatal(err)
	}
	notes, err := WalkNotes(root)
	if err != nil {
		t.Fatalf("WalkNotes empty: %v", err)
	}
	if len(notes) != 0 {
		t.Errorf("expected 0 notes, got %d: %v", len(notes), notes)
	}
}

// TestWalkNotes_Subdirs verifies that files in spec/, lab/, daily/ subdirs are
// included and get the right IDs.
func TestWalkNotes_Subdirs(t *testing.T) {
	root := t.TempDir()
	notesDir := filepath.Join(root, "docs", "notes")
	for _, sub := range []string{"spec", "lab", "daily"} {
		if err := os.MkdirAll(filepath.Join(notesDir, sub), 0755); err != nil {
			t.Fatal(err)
		}
	}
	files := map[string]string{
		filepath.Join(notesDir, "us001.md"):       "---\nstatus: ready\n---\n",
		filepath.Join(notesDir, "spec", "sp001.md"): "---\nstatus: done\n---\n",
		filepath.Join(notesDir, "lab", "poc001.md"): "---\nstatus: proposed\n---\n",
		filepath.Join(notesDir, "daily", "2026-06-12.md"): "# Today\n",
	}
	for p, content := range files {
		if err := os.WriteFile(p, []byte(content), 0644); err != nil {
			t.Fatal(err)
		}
	}
	notes, err := WalkNotes(root)
	if err != nil {
		t.Fatalf("WalkNotes subdirs: %v", err)
	}
	byID := make(map[string]Note)
	for _, n := range notes {
		byID[n.ID] = n
	}
	for _, id := range []string{"us001", "sp001", "poc001", "2026-06-12"} {
		if _, ok := byID[id]; !ok {
			t.Errorf("expected note %q, not found in walk result", id)
		}
	}
}
