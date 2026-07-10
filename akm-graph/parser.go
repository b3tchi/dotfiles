package main

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// frontmatter holds the parsed YAML front matter of a note.
type frontmatter struct {
	Aliases []string `yaml:"aliases"`
	Status  string   `yaml:"status"`
}

// Note represents a parsed markdown note.
type Note struct {
	// ID is the filename stem (e.g. "us006").
	ID string
	// AbsPath is the absolute file path.
	AbsPath string
	// FM is the parsed frontmatter (zero value if absent).
	FM frontmatter
	// Links is the list of wikilink targets extracted from the body.
	Links []string
}

// wikilinkRe matches [[target]], [[target|label]], [[target#section]],
// and combinations. Capture group 1 is the raw inner content.
var wikilinkRe = regexp.MustCompile(`\[\[([^\[\]]+)\]`)

// extractWikilinks returns the resolved target IDs from all [[wikilinks]]
// in text. Forms handled:
//   - [[id]]           → id
//   - [[id|label]]     → id
//   - [[id#section]]   → id
//   - [[id#sec|label]] → id
//
// Malformed (unclosed [[ or [[  ]]) → skipped.
// Wikilinks inside code fences are counted (documented limitation).
func extractWikilinks(text string) []string {
	matches := wikilinkRe.FindAllStringSubmatch(text, -1)
	out := make([]string, 0, len(matches))
	for _, m := range matches {
		inner := strings.TrimSpace(m[1])
		if inner == "" {
			continue
		}
		// Strip label: [[id|label]] → id
		if idx := strings.IndexByte(inner, '|'); idx >= 0 {
			inner = inner[:idx]
		}
		// Strip section: [[id#section]] → id
		if idx := strings.IndexByte(inner, '#'); idx >= 0 {
			inner = inner[:idx]
		}
		inner = strings.TrimSpace(inner)
		if inner != "" {
			out = append(out, inner)
		}
	}
	return out
}

// parseFrontmatter splits raw file content into frontmatter and body.
// If there is no leading "---\n...\n---" block, fm is zero-valued and
// body is the full content.
func parseFrontmatter(content []byte) (fm frontmatter, body []byte) {
	if !bytes.HasPrefix(content, []byte("---\n")) {
		return frontmatter{}, content
	}
	// Find the closing "---"
	rest := content[4:] // skip opening "---\n"
	idx := bytes.Index(rest, []byte("\n---"))
	if idx < 0 {
		// Unclosed front matter — treat whole file as body
		return frontmatter{}, content
	}
	fmBytes := rest[:idx]
	if err := yaml.Unmarshal(fmBytes, &fm); err != nil {
		// Malformed YAML — return empty fm, full body
		return frontmatter{}, content
	}
	body = rest[idx+4:] // skip "\n---"
	if len(body) > 0 && body[0] == '\n' {
		body = body[1:]
	}
	return fm, body
}

// parseNote reads and parses a single markdown file.
func parseNote(absPath string) (Note, error) {
	data, err := os.ReadFile(absPath)
	if err != nil {
		return Note{}, err
	}
	stem := strings.TrimSuffix(filepath.Base(absPath), ".md")
	fm, body := parseFrontmatter(data)
	links := extractWikilinks(string(body))
	return Note{
		ID:      stem,
		AbsPath: absPath,
		FM:      fm,
		Links:   links,
	}, nil
}

// hubFiles are the hub notes relative to the repo root (resolved at walk time).
// docs/notes/akm.md is a symlink to claude/akm/akm.md; the docs/notes walk skips
// symlinks, so the AKM overview hub is picked up here via os.Stat (which follows
// the link) instead of being dropped (dotfiles-2ry).
//
// docs/board.md and docs/product.md are intentionally excluded (dotfiles-t9v):
// they are navigation/meta index pages, not knowledge zettels. Their [[board]] /
// [[product]] back-links then fall to the non-zettel filter and are dropped.
var hubFiles = []string{"docs/notes/akm.md"}

// WalkNotes walks root for all *.md files under docs/notes/** and the two hub
// files docs/board.md and docs/product.md. root is the absolute path to the
// dotfiles/akm-graph root — the function resolves notes paths relative to the
// parent of root (i.e. root/..).
//
// For the actual server use case, call WalkNotes(repoRoot) directly.
func WalkNotes(repoRoot string) ([]Note, error) {
	notesDir := filepath.Join(repoRoot, "docs", "notes")
	var notes []Note

	// Walk docs/notes/**
	if _, err := os.Stat(notesDir); err == nil {
		err = filepath.WalkDir(notesDir, func(p string, d fs.DirEntry, err error) error {
			if err != nil {
				return nil // skip unreadable
			}
			if d.IsDir() {
				return nil
			}
			if d.Type()&fs.ModeSymlink != 0 {
				return nil
			}
			if strings.HasSuffix(d.Name(), ".md") {
				note, err := parseNote(p)
				if err != nil {
					return nil // skip unparseable
				}
				notes = append(notes, note)
			}
			return nil
		})
		if err != nil {
			return nil, err
		}
	}

	// Hub files
	for _, rel := range hubFiles {
		absHub := filepath.Join(repoRoot, rel)
		if _, err := os.Stat(absHub); err != nil {
			continue // hub file absent — skip
		}
		note, err := parseNote(absHub)
		if err != nil {
			continue
		}
		notes = append(notes, note)
	}

	return notes, nil
}

// nodeTypeFromID derives the node type from the note ID prefix.
// Hub notes (board, product) must be typed externally via isHub.
func nodeTypeFromID(id string, isHub bool) string {
	if isHub {
		return "hub"
	}
	prefixes := []string{
		"us", "sp", "im", "ft", "adr", "cat", "pn", "poc",
	}
	for _, p := range prefixes {
		if strings.HasPrefix(id, p) {
			// Verify next char is a digit (e.g. "us006" not "uspending")
			rest := id[len(p):]
			if len(rest) > 0 && rest[0] >= '0' && rest[0] <= '9' {
				return p
			}
		}
	}
	return "note"
}
