package main

import (
	"html/template"
	"net/http"
)

const indexTmpl = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>d2-router — diagram index</title>
<style>
body { font-family: sans-serif; max-width: 800px; margin: 2em auto; }
.warning { background: #fff3cd; border: 1px solid #ffc107; padding: .75em 1em; border-radius: 4px; margin-bottom: 1em; }
.collision { color: #d9534f; font-size: .85em; margin-left: .5em; }
ul { list-style: none; padding: 0; }
li { padding: .25em 0; border-bottom: 1px solid #eee; }
a { text-decoration: none; color: #0366d6; }
a:hover { text-decoration: underline; }
</style>
</head>
<body>
<h1>d2-router</h1>
{{if .RegistryMissing}}
<div class="warning">
  <strong>registry not found</strong> — set <code>$D2_ROUTER_REGISTRY</code> to a valid
  <code>projects.yaml</code> path or create <code>~/.config/project/projects.yaml</code>.
</div>
{{end}}
{{if not .Entries}}
<p>No <code>*.d2</code> files found in registered local projects.</p>
{{else}}
<ul>
{{range .Entries}}
  <li>
    <a href="{{.Route}}">{{.Route}}</a>
    {{if .Collision}}<span class="collision">⚠ collision (duplicate basename — first lexical path served)</span>{{end}}
  </li>
{{end}}
</ul>
{{end}}
</body>
</html>
`

var indexTemplate = template.Must(template.New("index").Funcs(template.FuncMap{
	"not": func(v interface{}) bool {
		switch val := v.(type) {
		case bool:
			return !val
		case []RouteEntry:
			return len(val) == 0
		}
		return false
	},
}).Parse(indexTmpl))

// indexHandler serves GET / with the precomputed IndexData.
type indexHandler struct {
	idx             *IndexData
	registryMissing bool
}

// newIndexHandler creates an http.Handler for GET /.
// registryMissing controls whether the warning banner is shown.
func newIndexHandler(idx *IndexData, registryMissing bool) http.Handler {
	return &indexHandler{idx: idx, registryMissing: registryMissing}
}

func (h *indexHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	data := struct {
		Entries         []RouteEntry
		RegistryMissing bool
	}{
		Entries:         h.idx.Entries,
		RegistryMissing: h.registryMissing,
	}

	if err := indexTemplate.Execute(w, data); err != nil {
		http.Error(w, "template error: "+err.Error(), http.StatusInternalServerError)
	}
}
