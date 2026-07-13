package main

import (
	"fmt"
	"html"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// isSTLExt reports whether path's extension is STL. Detection is
// extension-based, matching the rest of render.go's dispatch style (e.g.
// isImageExt, isVideoExt); content that turns out not to actually be a
// decodable STL still degrades safely -- renderSTL never inspects the
// content server-side at all (see renderSTLPage).
func isSTLExt(path string) bool {
	return strings.ToLower(filepath.Ext(path)) == ".stl"
}

// renderSTL serves path's STL content: by default (full=false) an HTML page
// embedding the vendored three.js/STLLoader/OrbitControls viewer bundle,
// which fetches and orbits the model directly -- STL has no thumbnail tier
// (ft005 api_surface STL row; sp008 Task 9 success criteria: "loads live
// directly, no thumbnail"). full=true streams the raw STL bytes verbatim.
//
// DEVIATION (flagged per sp008 Task 9 notes): the task's test_plan suggests
// a dedicated "?raw" query param for the byte stream. This reuses the
// EXISTING "?full" convention render.go's dispatch already threads through
// for image/video instead, because it is an exact fit -- "the underlying
// raw asset behind the default rendered view" is exactly what full already
// means for those renderers -- and it requires ZERO changes to server.go's
// handleFile (which already passes r.URL.Query().Has("full") to renderFile
// for every extension, STL included). The viewer page itself derives its
// fetch URL as window.location.pathname + "?full" client-side, so no
// server-side request-path threading is needed either.
func renderSTL(w http.ResponseWriter, path string, fi os.FileInfo, full bool) {
	if full {
		serveOriginalSTL(w, path, fi)
		return
	}
	renderSTLPage(w, path, fi)
}

// serveOriginalSTL streams path's bytes to w unmodified via io.Copy, which
// never buffers more than its internal fixed-size chunk in memory --
// server-side memory stays bounded regardless of mesh size (sp008 Task 9
// edge case: very large mesh must be bounded/streamed, not fully buffered).
// Parity with serveOriginalImage/serveOriginalVideo's full-res tier: no
// decode, no re-encode, byte-identical to the source file.
func serveOriginalSTL(w http.ResponseWriter, path string, fi os.FileInfo) {
	f, err := os.Open(path)
	if err != nil {
		renderFallback(w, path, fi)
		return
	}
	defer f.Close()

	w.Header().Set("Content-Type", "model/stl")
	w.Header().Set("Content-Length", strconv.FormatInt(fi.Size(), 10))
	_, _ = io.Copy(w, f)
}

// renderSTLPage always returns 200 HTML embedding the vendored viewer bundle
// at /static/stl-viewer.js -- it never inspects the STL bytes themselves, so
// a malformed or empty file still gets a normal, loading page (sp008 Task 9
// edge cases: malformed STL -> viewer shows error state, page still loads;
// empty file). Parsing (and surfacing a parse failure as an inline error
// state) happens entirely client-side in the vendored bundle's fetch+parse,
// per its own try/catch around THREE.STLLoader.parse -- this keeps the
// server handler simple and unable to 500 on bad mesh content, since it
// never touches mesh content at all. The model source URL is derived
// client-side (window.location.pathname + "?full"), so this handler needs
// no request-path threading, only the resolved filesystem path (for the
// page title) and its FileInfo (kept for symmetry with renderImage/
// renderVideo's signature; currently unused otherwise).
func renderSTLPage(w http.ResponseWriter, path string, _ os.FileInfo) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html><html><head><meta charset="utf-8"><title>%s</title>`+
		`<style>html,body{margin:0;height:100%%;background:#111;overflow:hidden}`+
		`#stl-canvas{position:fixed;inset:0;width:100%%;height:100%%;display:block}`+
		`#stl-error{position:fixed;inset:0;display:none;align-items:center;justify-content:center;`+
		`font:14px monospace;color:#f66;background:#111;text-align:center;padding:1em;white-space:pre-wrap}`+
		`</style></head>`+
		`<body class="preview-stl">`+
		`<canvas id="stl-canvas"></canvas>`+
		`<div id="stl-error"></div>`+
		`<script src="/static/stl-viewer.js"></script>`+
		`<script>window.PreviewSTL && window.PreviewSTL.init({`+
		`canvas: document.getElementById("stl-canvas"), `+
		`errorEl: document.getElementById("stl-error"), `+
		`src: window.location.pathname + "?full"`+
		`});</script>`+
		`</body></html>`,
		html.EscapeString(filepath.Base(path)))
}
