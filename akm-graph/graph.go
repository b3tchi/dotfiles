package main

import (
	"sort"
)

// Node represents a single zettel node in the graph.
type Node struct {
	ID     string `json:"id"`
	Type   string `json:"type"`
	Status string `json:"status"`
	Alias  string `json:"alias"`
	Degree int    `json:"degree"`
	Ghost  bool   `json:"ghost"`
}

// Link represents a directed edge source → target.
type Link struct {
	Source string `json:"source"`
	Target string `json:"target"`
}

// Graph is the full serialisable graph payload matching the ft004 api_surface:
//
//	{nodes: [{id, type, status, alias, degree, ghost}], links: [{source, target}]}
type Graph struct {
	Nodes []Node `json:"nodes"`
	Links []Link `json:"links"`
}

// hubIDs is the set of IDs for hub files (board, product).
var hubIDs = map[string]bool{
	"board":   true,
	"product": true,
}

// BuildGraph constructs the full Graph from a set of parsed notes.
//
// Rules:
//   - One Node per Note (id = filename stem). Type from nodeTypeFromID.
//   - One Node per dangling wikilink target (ghost:true).
//   - Self-links dropped.
//   - Duplicate source→target pairs deduplicated to one Link.
//   - Degree = number of links incident on the node (in + out).
func BuildGraph(notes []Note) Graph {
	// Build lookup of known note IDs → Note
	noteByID := make(map[string]Note, len(notes))
	for _, n := range notes {
		noteByID[n.ID] = n
	}

	// Collect all deduped edges first (before degree computation).
	type edgeKey struct{ src, dst string }
	edgeSeen := make(map[edgeKey]bool)
	// Non-nil so an edge-free graph serializes as "links": [] per the
	// ft004 api_surface (never null).
	links := []Link{}

	for _, n := range notes {
		for _, target := range n.Links {
			if target == n.ID {
				continue // drop self-link
			}
			k := edgeKey{n.ID, target}
			if edgeSeen[k] {
				continue
			}
			edgeSeen[k] = true
			links = append(links, Link{Source: n.ID, Target: target})
		}
	}

	// Compute degree per node (count each incident link once per direction).
	degree := make(map[string]int)
	for _, l := range links {
		degree[l.Source]++
		degree[l.Target]++
	}

	// Build ghost set: targets that have no Note.
	ghostIDs := make(map[string]bool)
	for _, l := range links {
		if _, ok := noteByID[l.Target]; !ok {
			ghostIDs[l.Target] = true
		}
	}

	// Assemble nodes from known notes.
	nodes := make([]Node, 0, len(notes)+len(ghostIDs))
	for _, n := range notes {
		alias := ""
		if len(n.FM.Aliases) > 0 {
			alias = n.FM.Aliases[0]
		}
		nodes = append(nodes, Node{
			ID:     n.ID,
			Type:   nodeTypeFromID(n.ID, hubIDs[n.ID]),
			Status: n.FM.Status,
			Alias:  alias,
			Degree: degree[n.ID],
			Ghost:  false,
		})
	}

	// Append ghost nodes.
	for id := range ghostIDs {
		nodes = append(nodes, Node{
			ID:     id,
			Type:   nodeTypeFromID(id, false),
			Status: "",
			Alias:  "",
			Degree: degree[id],
			Ghost:  true,
		})
	}

	// Stable sort for deterministic output.
	sort.Slice(nodes, func(i, j int) bool {
		return nodes[i].ID < nodes[j].ID
	})
	sort.Slice(links, func(i, j int) bool {
		if links[i].Source != links[j].Source {
			return links[i].Source < links[j].Source
		}
		return links[i].Target < links[j].Target
	})

	return Graph{Nodes: nodes, Links: links}
}

// BuildGraphFromRoot walks the repo at repoRoot and builds the full graph.
// This is the primary entry point for the HTTP server.
func BuildGraphFromRoot(repoRoot string) (Graph, error) {
	notes, err := WalkNotes(repoRoot)
	if err != nil {
		return Graph{}, err
	}
	return BuildGraph(notes), nil
}
