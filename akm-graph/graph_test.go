package main

import (
	"encoding/json"
	"flag"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

var update = flag.Bool("update", false, "regenerate golden files")

// TestBuildGraphFromRoot_SymlinkedAkmHub proves the AKM overview hub note,
// which ships as docs/notes/akm.md symlinked to claude/akm/akm.md, appears as a
// non-ghost "hub" node with its frontmatter parsed — not dropped by the walk's
// symlink guard and not left as a ghost of an incoming [[akm]] link
// (regression for dotfiles-2ry).
func TestBuildGraphFromRoot_SymlinkedAkmHub(t *testing.T) {
	root := t.TempDir()
	notes := filepath.Join(root, "docs", "notes")
	if err := os.MkdirAll(notes, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "docs", "board.md"), []byte("# board"), 0644); err != nil {
		t.Fatal(err)
	}
	// A note that links to [[akm]] — akm must resolve to a real node, not a ghost.
	if err := os.WriteFile(filepath.Join(notes, "us001.md"), []byte("# us [[akm]]"), 0644); err != nil {
		t.Fatal(err)
	}
	// The hub note lives outside docs/notes and is symlinked in as akm.md,
	// mirroring the real docs/notes/akm.md -> claude/akm/akm.md layout.
	target := filepath.Join(root, "hub-akm.md")
	if err := os.WriteFile(target, []byte("---\naliases:\n  - akm-model\n---\n# AKM"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(notes, "akm.md")); err != nil {
		t.Skipf("symlinks unsupported on this platform: %v", err)
	}

	g, err := BuildGraphFromRoot(root)
	if err != nil {
		t.Fatalf("BuildGraphFromRoot: %v", err)
	}

	var akm *Node
	for i := range g.Nodes {
		if g.Nodes[i].ID == "akm" {
			akm = &g.Nodes[i]
		}
	}
	if akm == nil {
		t.Fatalf("akm node absent — symlinked hub note dropped; nodes=%d", len(g.Nodes))
	}
	if akm.Ghost {
		t.Errorf("akm node is a ghost; want a real node parsed from the symlink target")
	}
	if akm.Type != "hub" {
		t.Errorf("akm node type = %q, want hub", akm.Type)
	}
	if akm.Alias != "akm-model" {
		t.Errorf("akm alias = %q, want akm-model (frontmatter parsed via symlink)", akm.Alias)
	}
}

// TestBuildGraph_Basic verifies node and link construction.
func TestBuildGraph_Basic(t *testing.T) {
	notes := []Note{
		{ID: "us001", FM: frontmatter{Aliases: []string{"story-one"}, Status: "ready"}, Links: []string{"sp001", "ft001"}},
		{ID: "sp001", FM: frontmatter{Status: "done"}, Links: []string{"us001"}},
		{ID: "ft001", FM: frontmatter{Aliases: []string{"feature-one"}, Status: "proposed"}, Links: []string{}},
	}
	g := BuildGraph(notes)

	// All 3 input notes should appear as nodes.
	if len(g.Nodes) != 3 {
		t.Errorf("expected 3 nodes, got %d", len(g.Nodes))
	}

	// Check links: us001→sp001, us001→ft001, sp001→us001 = 3 edges
	if len(g.Links) != 3 {
		t.Errorf("expected 3 links, got %d: %v", len(g.Links), g.Links)
	}
}

// TestBuildGraph_SelfLink verifies self-links are dropped.
func TestBuildGraph_SelfLink(t *testing.T) {
	notes := []Note{
		{ID: "us001", FM: frontmatter{}, Links: []string{"us001", "sp001"}},
		{ID: "sp001", FM: frontmatter{}, Links: []string{}},
	}
	g := BuildGraph(notes)
	for _, l := range g.Links {
		if l.Source == l.Target {
			t.Errorf("self-link not dropped: %v", l)
		}
	}
	// Only us001→sp001 should remain.
	if len(g.Links) != 1 {
		t.Errorf("expected 1 link, got %d: %v", len(g.Links), g.Links)
	}
}

// TestBuildGraph_DuplicateLinks verifies duplicate source→target pairs collapse to one edge.
func TestBuildGraph_DuplicateLinks(t *testing.T) {
	notes := []Note{
		{ID: "us001", FM: frontmatter{}, Links: []string{"sp001", "sp001", "sp001"}},
		{ID: "sp001", FM: frontmatter{}, Links: []string{}},
	}
	g := BuildGraph(notes)
	if len(g.Links) != 1 {
		t.Errorf("expected 1 deduped link, got %d: %v", len(g.Links), g.Links)
	}
}

// TestBuildGraph_GhostNode verifies dangling link targets become ghost nodes.
func TestBuildGraph_GhostNode(t *testing.T) {
	notes := []Note{
		{ID: "us001", FM: frontmatter{Status: "ready"}, Links: []string{"nonexistent-target"}},
	}
	g := BuildGraph(notes)

	// Should have us001 + ghost node.
	if len(g.Nodes) != 2 {
		t.Errorf("expected 2 nodes (1 real + 1 ghost), got %d", len(g.Nodes))
	}

	var ghostNode *Node
	for i := range g.Nodes {
		if g.Nodes[i].ID == "nonexistent-target" {
			ghostNode = &g.Nodes[i]
		}
	}
	if ghostNode == nil {
		t.Fatal("ghost node not found")
	}
	if !ghostNode.Ghost {
		t.Error("ghost node should have ghost:true")
	}
	if ghostNode.Status != "" {
		t.Errorf("ghost node status should be empty, got %q", ghostNode.Status)
	}
}

// TestBuildGraph_Degree verifies degree computation (in + out counts each edge once per endpoint).
func TestBuildGraph_Degree(t *testing.T) {
	// us001 → sp001, us001 → ft001, sp001 → us001
	// Degrees: us001: 3 (out:2 + in:1), sp001: 2, ft001: 1
	notes := []Note{
		{ID: "us001", FM: frontmatter{}, Links: []string{"sp001", "ft001"}},
		{ID: "sp001", FM: frontmatter{}, Links: []string{"us001"}},
		{ID: "ft001", FM: frontmatter{}, Links: []string{}},
	}
	g := BuildGraph(notes)
	byID := make(map[string]Node)
	for _, n := range g.Nodes {
		byID[n.ID] = n
	}
	if byID["us001"].Degree != 3 {
		t.Errorf("us001 degree: got %d, want 3", byID["us001"].Degree)
	}
	if byID["sp001"].Degree != 2 {
		t.Errorf("sp001 degree: got %d, want 2", byID["sp001"].Degree)
	}
	if byID["ft001"].Degree != 1 {
		t.Errorf("ft001 degree: got %d, want 1", byID["ft001"].Degree)
	}
}

// TestBuildGraph_EmptyNotes verifies that empty input serializes to the exact
// ft004 api_surface shape: nodes and links MUST be JSON arrays, never null.
func TestBuildGraph_EmptyNotes(t *testing.T) {
	g := BuildGraph(nil)
	b, err := json.Marshal(g)
	if err != nil {
		t.Fatalf("json.Marshal empty graph: %v", err)
	}
	want := `{"nodes":[],"links":[]}`
	if string(b) != want {
		t.Errorf("empty graph JSON:\n  got:  %s\n  want: %s", b, want)
	}
}

// TestBuildGraph_HubNodes verifies board and product get type "hub".
func TestBuildGraph_HubNodes(t *testing.T) {
	notes := []Note{
		{ID: "board", FM: frontmatter{}, Links: []string{}},
		{ID: "product", FM: frontmatter{}, Links: []string{}},
		{ID: "us001", FM: frontmatter{}, Links: []string{"board"}},
	}
	g := BuildGraph(notes)
	byID := make(map[string]Node)
	for _, n := range g.Nodes {
		byID[n.ID] = n
	}
	if byID["board"].Type != "hub" {
		t.Errorf("board type: got %q, want hub", byID["board"].Type)
	}
	if byID["product"].Type != "hub" {
		t.Errorf("product type: got %q, want hub", byID["product"].Type)
	}
}

// TestBuildGraph_Unicode verifies unicode aliases survive the round-trip.
func TestBuildGraph_Unicode(t *testing.T) {
	notes := []Note{
		{ID: "us001", FM: frontmatter{Aliases: []string{"日本語テスト"}, Status: "ready"}, Links: []string{}},
	}
	g := BuildGraph(notes)
	if len(g.Nodes) != 1 {
		t.Fatalf("expected 1 node, got %d", len(g.Nodes))
	}
	if g.Nodes[0].Alias != "日本語テスト" {
		t.Errorf("alias: got %q, want 日本語テスト", g.Nodes[0].Alias)
	}
}

// TestBuildGraph_NodeAlias verifies first alias is taken and no-alias is empty.
func TestBuildGraph_NodeAlias(t *testing.T) {
	notes := []Note{
		{ID: "us001", FM: frontmatter{Aliases: []string{"first", "second"}}, Links: []string{}},
		{ID: "sp001", FM: frontmatter{}, Links: []string{}},
	}
	g := BuildGraph(notes)
	byID := make(map[string]Node)
	for _, n := range g.Nodes {
		byID[n.ID] = n
	}
	if byID["us001"].Alias != "first" {
		t.Errorf("us001 alias: got %q, want first", byID["us001"].Alias)
	}
	if byID["sp001"].Alias != "" {
		t.Errorf("sp001 alias: got %q, want empty", byID["sp001"].Alias)
	}
}

// TestBuildGraphFromRoot_Fixture is the golden-file test.
// Run with -update to regenerate the golden file.
func TestBuildGraphFromRoot_Fixture(t *testing.T) {
	fixtureRoot := filepath.Join("fixtures")
	if _, err := os.Stat(fixtureRoot); os.IsNotExist(err) {
		t.Skipf("fixture root %s not found", fixtureRoot)
	}

	g, err := BuildGraphFromRoot(fixtureRoot)
	if err != nil {
		t.Fatalf("BuildGraphFromRoot: %v", err)
	}

	// Stable sort for golden comparison.
	sort.Slice(g.Nodes, func(i, j int) bool { return g.Nodes[i].ID < g.Nodes[j].ID })
	sort.Slice(g.Links, func(i, j int) bool {
		if g.Links[i].Source != g.Links[j].Source {
			return g.Links[i].Source < g.Links[j].Source
		}
		return g.Links[i].Target < g.Links[j].Target
	})

	got, err := json.MarshalIndent(g, "", "  ")
	if err != nil {
		t.Fatalf("json.MarshalIndent: %v", err)
	}

	goldenPath := filepath.Join("fixtures", "golden.json")
	if *update {
		if err := os.WriteFile(goldenPath, got, 0644); err != nil {
			t.Fatalf("write golden: %v", err)
		}
		t.Logf("golden file updated: %s", goldenPath)
		return
	}

	want, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("read golden: %v — run with -update to generate", err)
	}

	if string(got) != string(want) {
		t.Errorf("graph does not match golden.\ngot:\n%s\nwant:\n%s", got, want)
	}
}

// TestBuildGraphFromRoot_Empty verifies that an empty notes dir produces valid empty JSON.
func TestBuildGraphFromRoot_Empty(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "docs", "notes"), 0755); err != nil {
		t.Fatal(err)
	}
	g, err := BuildGraphFromRoot(root)
	if err != nil {
		t.Fatalf("BuildGraphFromRoot empty: %v", err)
	}
	b, err := json.Marshal(g)
	if err != nil {
		t.Fatalf("json.Marshal: %v", err)
	}
	// Must be the exact ft004 shape: arrays, never null.
	want := `{"nodes":[],"links":[]}`
	if string(b) != want {
		t.Errorf("empty root graph JSON:\n  got:  %s\n  want: %s", b, want)
	}
}
