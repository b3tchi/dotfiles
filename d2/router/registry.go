package main

import (
	"fmt"
	"io/fs"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Registry maps project name → absolute local path.
// SSH-only entries are excluded at load time.
type Registry map[string]string

// projectsFile is the raw structure of projects.yaml per ft001 schema.
type projectsFile struct {
	Projects map[string]projectEntry `yaml:"projects"`
}

type projectEntry struct {
	Path string  `yaml:"path"`
	SSH  *string `yaml:"ssh"`
}

// loadRegistry parses projects.{name}.{path,ssh} from the given file path.
// Entries with a non-empty ssh value are excluded (local-only routing).
// Returns nil + error on parse failure.
// Returns nil + error if the file cannot be read (caller handles missing-file
// gracefully by showing a warning and serving an empty index).
func loadRegistry(path string) (Registry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("loadRegistry: read %s: %w", path, err)
	}

	var pf projectsFile
	if err := yaml.Unmarshal(data, &pf); err != nil {
		return nil, fmt.Errorf("loadRegistry: parse %s: %w", path, err)
	}

	reg := make(Registry, len(pf.Projects))
	for name, entry := range pf.Projects {
		// ft001 normalisation: ssh nil or empty string → local
		if entry.SSH != nil && *entry.SSH != "" {
			log.Printf("registry: skipping ssh project %q (ssh=%q)", name, *entry.SSH)
			continue
		}
		reg[name] = entry.Path
	}
	return reg, nil
}

// RouteEntry is a single /{project}/{basename} route.
type RouteEntry struct {
	Route     string
	AbsPath   string
	Collision bool // another file in the same project shares this basename
}

// IndexData holds the full computed route set.
type IndexData struct {
	Entries         []RouteEntry
	RegistryMissing bool
}

// walkProjectFiles returns a map of route→absPath for all *.d2 files under root,
// skipping dot-dirs and not following symlinks.
// Duplicate basenames: the lexically-first absolute path wins; the collision map
// records basename→true for any basename that had duplicates.
func walkProjectFiles(project, root string) (map[string]RouteEntry, map[string]bool) {
	// Collect all .d2 files (absPath) under the root.
	var found []string
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			return nil // skip unreadable entries, don't abort
		}
		if d.IsDir() {
			if strings.HasPrefix(d.Name(), ".") && p != root {
				return filepath.SkipDir
			}
			// Don't follow symlinked dirs — WalkDir uses lstat by default.
			return nil
		}
		// Skip symlinked files.
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if strings.HasSuffix(d.Name(), ".d2") {
			found = append(found, p)
		}
		return nil
	})
	if err != nil {
		log.Printf("walkProjectFiles: walk %s: %v", root, err)
	}

	// Sort so the lexically-first path wins on basename collision.
	sort.Strings(found)

	routes := make(map[string]RouteEntry)
	// basename → first path that claimed it
	basenameSeen := make(map[string]string)
	collisions := make(map[string]bool)

	for _, absPath := range found {
		basename := filepath.Base(absPath)
		route := "/" + project + "/" + url.PathEscape(basename)

		if first, dup := basenameSeen[basename]; dup {
			log.Printf("walkProjectFiles: project %q basename collision %q: keeping %q, skipping %q",
				project, basename, first, absPath)
			collisions[basename] = true
			continue
		}
		basenameSeen[basename] = absPath
		routes[route] = RouteEntry{
			Route:   route,
			AbsPath: absPath,
		}
	}

	return routes, collisions
}

// buildIndex constructs IndexData from the Registry by walking each project path.
// Projects whose path does not exist are skipped with a warning.
func buildIndex(reg Registry) *IndexData {
	idx := &IndexData{}

	// Deterministic order.
	names := make([]string, 0, len(reg))
	for name := range reg {
		names = append(names, name)
	}
	sort.Strings(names)

	for _, name := range names {
		root := reg[name]
		if _, err := os.Stat(root); os.IsNotExist(err) {
			log.Printf("buildIndex: project %q path %q does not exist, skipping", name, root)
			continue
		}

		routes, collisions := walkProjectFiles(name, root)

		// Build sorted entries for stable output.
		routeKeys := make([]string, 0, len(routes))
		for r := range routes {
			routeKeys = append(routeKeys, r)
		}
		sort.Strings(routeKeys)

		for _, route := range routeKeys {
			entry := routes[route]
			basename := filepath.Base(entry.AbsPath)
			entry.Collision = collisions[basename]
			idx.Entries = append(idx.Entries, entry)
		}
	}

	return idx
}
