package main

import "embed"

// staticFS embeds the daemon's static viewer assets so preview-d serves
// them from the binary regardless of the working directory — the [[ft004]]
// offline-safe precedent (no target-side build, no CDN). Task 1 seeded a
// placeholder so the go:embed directive had a file to match before any
// real asset existed; sp022 Task 8 removed the browser-shell assets the
// wry host depended on (the QML client replaces that host entirely) —
// the directory embed still just picks up whatever remains (currently the
// STL viewer bundle the web tier's stl delegate loads via /static/).
//
//go:embed static
var staticFS embed.FS
