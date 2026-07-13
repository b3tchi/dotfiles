package main

import "embed"

// staticFS embeds the daemon's static viewer assets so preview-d serves
// them from the binary regardless of the working directory — the [[ft004]]
// offline-safe precedent (no target-side build, no CDN). Task 1 seeds a
// placeholder so the go:embed directive has a file to match; later sp008
// tasks add shell.html / app.js / style.css / the STL viewer bundle here.
//
//go:embed static
var staticFS embed.FS
