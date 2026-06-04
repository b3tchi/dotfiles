package main

import (
	"html/template"
	"net/http"
	"strings"
)

const indexTmpl = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>d2-router — diagram index</title>
<style>
body { font-family: sans-serif; max-width: 900px; margin: 2em auto; }
.warning { background: #fff3cd; border: 1px solid #ffc107; padding: .75em 1em; border-radius: 4px; margin-bottom: 1em; }
.collision { color: #d9534f; font-size: .85em; margin-left: .5em; }
.controls { display: flex; gap: .5em; align-items: center; flex-wrap: wrap; }
.stop-all { margin-bottom: 1em; }
ul { list-style: none; padding: 0; }
li { padding: .4em 0; border-bottom: 1px solid #eee; display: flex; align-items: center; gap: .75em; flex-wrap: wrap; }
a { text-decoration: none; color: #0366d6; flex: 1 1 auto; }
a:hover { text-decoration: underline; }
button { cursor: pointer; border: 1px solid #ccc; border-radius: 3px; padding: .2em .6em; font-size: .85em; background: #f6f8fa; }
button:hover { background: #e1e4e8; }
button.danger { border-color: #d9534f; color: #d9534f; }
button.danger:hover { background: #fdf2f2; }
.status-msg { font-size: .8em; color: #555; }
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
<div class="stop-all controls">
  <button class="danger" onclick="apiPost('/api/stop-all').then(()=>location.reload())">stop-all</button>
  <span id="stopall-msg" class="status-msg"></span>
</div>
{{if not .Entries}}
<p>No <code>*.d2</code> files found in registered local projects.</p>
{{else}}
<ul>
{{range .Entries}}
  <li>
    <a href="{{.Route}}">{{.Route}}</a>
    {{if .Collision}}<span class="collision">⚠ collision (duplicate basename — first lexical path served)</span>{{end}}
    <span class="controls">
      <button onclick="apiPost('/api/reload{{.Route}}').then(r=>showMsg(this,r))">reload</button>
      <button onclick="apiPost('/api/restart{{.Route}}').then(r=>showMsg(this,r))">restart</button>
      <button class="danger" onclick="apiPost('/api/stop{{.Route}}').then(r=>showMsg(this,r))">stop</button>
    </span>
  </li>
{{end}}
</ul>
{{end}}
<script>
// apiPost sends a POST to the given path and returns a result message string.
async function apiPost(path) {
  try {
    const resp = await fetch(path, { method: 'POST' });
    const body = await resp.json().catch(() => ({}));
    if (!resp.ok) {
      return 'error: ' + (body.error || resp.status);
    }
    return body.status || 'ok';
  } catch (e) {
    return 'error: ' + e.message;
  }
}

// showMsg displays a transient status message next to the clicked button.
function showMsg(btn, msg) {
  const existing = btn.parentElement.querySelector('.btn-msg');
  const el = existing || document.createElement('span');
  el.className = 'btn-msg status-msg';
  el.textContent = msg;
  if (!existing) btn.parentElement.appendChild(el);
  clearTimeout(el._timer);
  el._timer = setTimeout(() => el.remove(), 3000);
}
</script>
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

// indexTemplateAPIButtons is a compile-time sanity check that the template
// references the expected API paths. It is evaluated once at init time.
// Any failure here is a build-time hint to add the missing button.
var indexTemplateAPIButtons = func() bool {
	ok := strings.Contains(indexTmpl, "/api/reload") &&
		strings.Contains(indexTmpl, "/api/restart") &&
		strings.Contains(indexTmpl, "/api/stop") &&
		strings.Contains(indexTmpl, "/api/stop-all") &&
		strings.Contains(indexTmpl, "fetch")
	if !ok {
		panic("index template is missing required API button references")
	}
	return ok
}()
