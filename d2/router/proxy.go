package main

import (
	"bytes"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// watchJSOldPattern is the literal template-literal ws:// connect string
// that d2 v0.7.1 emits in watch.js (including the surrounding backticks).
// Rewrite: `ws://${window.location.host}/watch` → `/{key}/watch`
const watchJSOldPattern = "`ws://${window.location.host}/watch`"

// htmlStaticOld is the root-absolute "/static/ prefix found in d2 v0.7.1 HTML.
const htmlStaticOld = `"/static/`

// probeVersion is the d2 version these patterns were confirmed against.
const probeVersion = "v0.7.1"

// ProxyHandler implements http.Handler for /{project}/{file}[/...] routes.
// It ensures the child is running, strips the prefix, proxies the request,
// and rewrites two known body patterns from d2's served assets.
type ProxyHandler struct {
	idx *IndexData
	reg Registry // project name → root path, for lazy re-walk on a route miss
	cm  *ChildManager

	// rewriteWarned tracks (key, rewriteType) pairs that have already logged
	// a warning so we emit at most one warning per child per type per daemon lifetime.
	mu            sync.Mutex
	rewriteWarned map[string]bool

	// routes is the current route set, replaced wholesale on re-walk
	// (copy-on-write). Readers Load() it lock-free; rebuilds serialize on
	// walkMu and Store() a fresh cache. Never mutated in place.
	routes atomic.Pointer[routeCache]

	// walkMu serializes re-walks and guards lastWalk. Held across the whole
	// walk+rebuild so two projects' rebuilds can't race a Load→Store clobber.
	walkMu   sync.Mutex
	lastWalk map[string]time.Time // project → last re-walk attempt (debounce)
}

// routeCache is one immutable snapshot of the route set, in the two lookup
// forms ServeHTTP needs. Swapped atomically; never mutated after Store.
type routeCache struct {
	byRaw     map[string]RouteEntry // route as stored (URL-encoded)
	byDecoded map[string]RouteEntry // URL-decoded route (Go pre-decodes r.URL.Path)
}

// rewalkDebounce caps how often a single project is re-walked, so a flood of
// 404s for a genuinely-absent file can't spin the walker. A var so tests can
// shorten or zero it (mirrors children.go's tunable-timeout style).
var rewalkDebounce = 500 * time.Millisecond

// buildRouteCache builds an immutable routeCache from a flat entry list.
func buildRouteCache(entries []RouteEntry) *routeCache {
	rc := &routeCache{
		byRaw:     make(map[string]RouteEntry, len(entries)),
		byDecoded: make(map[string]RouteEntry, len(entries)),
	}
	for _, e := range entries {
		rc.byRaw[e.Route] = e
		if decoded, err := url.PathUnescape(e.Route); err == nil {
			rc.byDecoded[decoded] = e
		}
	}
	return rc
}

// NewProxyHandler creates a ProxyHandler backed by the given index, registry
// and child manager. reg may be nil (tests with a fixed index and no re-walk
// need): a nil reg simply means a route miss can never be reconciled.
func NewProxyHandler(idx *IndexData, reg Registry, cm *ChildManager) *ProxyHandler {
	p := &ProxyHandler{
		idx:           idx,
		reg:           reg,
		cm:            cm,
		rewriteWarned: make(map[string]bool),
		lastWalk:      make(map[string]time.Time),
	}
	p.routes.Store(buildRouteCache(idx.Entries))
	return p
}

// lookupRoute finds a RouteEntry for a request path.
// Go's HTTP server pre-decodes r.URL.Path, so we check the decoded map first,
// then fall back to the raw map.
//
// On a miss the route set is a snapshot from the last walk, so a .d2 created
// after that walk is absent (dotfiles-t1o). Re-walk the project this path
// names and retry once. resolveInProject on the daemon happily hands the
// browser a URL for such a file, so routing must be willing to catch up or
// the preview 404s.
func (p *ProxyHandler) lookupRoute(reqPath string) (RouteEntry, bool) {
	if e, ok := lookupIn(p.routes.Load(), reqPath); ok {
		// A cached route can outlive its file: it may have been deleted since
		// the walk that indexed it (dotfiles-3tj). Serving it would lazy-spawn
		// a d2 --watch child on a missing file that the reaper immediately
		// kills — a flap on every re-request. Verify existence; if gone, drop
		// the route (best-effort debounced re-walk) and fall through to a miss
		// so this request 404s instead of spawning.
		if fileExists(e.AbsPath) {
			return e, true
		}
		p.rewalkProject(projectFromRoute(reqPath))
		return RouteEntry{}, false
	}
	project := projectFromRoute(reqPath)
	if project == "" || !p.rewalkProject(project) {
		return RouteEntry{}, false
	}
	return lookupIn(p.routes.Load(), reqPath)
}

// fileExists reports whether path resolves to an existing filesystem entry.
// Only a definitive os.ErrNotExist counts as absent — a transient stat error
// (permission, I/O) is treated as "exists" so a working preview is never
// dropped over a glitch. Mirrors the reaper's deletion check in children.go.
func fileExists(path string) bool {
	_, err := os.Stat(path)
	return !errors.Is(err, os.ErrNotExist)
}

// lookupIn checks the decoded map first (Go pre-decodes paths), then raw.
func lookupIn(rc *routeCache, reqPath string) (RouteEntry, bool) {
	if e, ok := rc.byDecoded[reqPath]; ok {
		return e, true
	}
	e, ok := rc.byRaw[reqPath]
	return e, ok
}

// projectFromRoute extracts the project name (first segment) from a
// "/{project}/{file}" route path, or "" if there is no such segment.
func projectFromRoute(reqPath string) string {
	trimmed := strings.TrimPrefix(reqPath, "/")
	i := strings.IndexByte(trimmed, '/')
	if i <= 0 {
		return ""
	}
	return trimmed[:i]
}

// rewalkProject re-walks one project's root and swaps in a route cache that
// keeps every other project's routes untouched, replacing only this
// project's with the fresh walk. Returns whether a walk actually ran (false
// when the project is unknown, its root is gone, or the debounce window is
// still open). Serialized under walkMu — the walk is the slow part, but
// serializing under a 404 flood is desirable (no thundering herd) and it
// removes the Load→Store clobber two concurrent project rebuilds would race.
func (p *ProxyHandler) rewalkProject(project string) bool {
	root, ok := p.reg[project]
	if !ok {
		return false
	}

	p.walkMu.Lock()
	defer p.walkMu.Unlock()

	if last, seen := p.lastWalk[project]; seen && time.Since(last) < rewalkDebounce {
		return false
	}
	p.lastWalk[project] = time.Now()

	if _, err := os.Stat(root); err != nil {
		return false
	}
	routes, collisions := walkProjectFiles(project, root)

	prefix := "/" + project + "/"
	cur := p.routes.Load()
	entries := make([]RouteEntry, 0, len(cur.byRaw)+len(routes))
	for route, e := range cur.byRaw {
		if !strings.HasPrefix(route, prefix) {
			entries = append(entries, e) // keep other projects verbatim
		}
	}
	for _, e := range routes {
		e.Collision = collisions[filepath.Base(e.AbsPath)]
		entries = append(entries, e)
	}
	p.routes.Store(buildRouteCache(entries))
	return true
}

// ServeHTTP handles all requests matching /{project}/{file}[/...].
func (p *ProxyHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Reject path traversal before any routing. The check runs on the *decoded,
	// pre-clean* path: a path is hostile if any segment is exactly ".." or if
	// path.Clean changes it (i.e. it was not already in canonical form). We must
	// NOT test strings.Contains(path.Clean(p), "..") — Clean *resolves* ".."
	// segments, so the very thing we want to reject is removed before the test.
	//
	// Go pre-decodes r.URL.Path, but RawPath can hide separators behind %2f and
	// dot-dots behind %2e%2e, so we additionally check the fully-decoded RawPath.
	decodedPath := r.URL.Path
	if hasTraversal(decodedPath) {
		writeJSONErr(w, http.StatusBadRequest, "path traversal rejected")
		return
	}
	if r.URL.RawPath != "" {
		if decoded, err := url.PathUnescape(r.URL.RawPath); err == nil {
			if hasTraversal(decoded) {
				writeJSONErr(w, http.StatusBadRequest, "path traversal rejected")
				return
			}
		}
	}

	// Prefer the raw (percent-encoded) path for route lookup so that routes
	// registered with url.PathEscape (e.g. /my%20proj/file.d2) match correctly.
	// Fall back to the decoded path when RawPath is absent.
	lookupPath := decodedPath
	if r.URL.RawPath != "" {
		lookupPath = r.URL.RawPath
	}

	// Parse /{project}/{file}[/rest] from the lookup path.
	key, suffix := splitKeyFromPath(lookupPath)
	if key == "" {
		http.NotFound(w, r)
		return
	}

	// Look up the route. The key came from splitKeyFromPath which operates on
	// the lookupPath (raw or decoded). We reconstruct the route path and look it up.
	entry, ok := p.lookupRoute("/" + key)
	if !ok {
		http.NotFound(w, r)
		return
	}

	// Use the canonical key from the index entry (strip leading "/").
	// This ensures the key is in the same encoded form as used in the ChildManager.
	canonKey, canonSuffix := splitKeyFromPath(entry.Route)
	if canonKey == "" {
		canonKey = key
	}
	_ = canonSuffix
	key = canonKey

	// Ensure the child is running (lazy-spawn).
	child, err := p.cm.Ensure(key, entry.AbsPath)
	if err != nil {
		log.Printf("proxy: %q: ensure child: %v", key, err)
		writeJSONErr(w, http.StatusBadGateway, fmt.Sprintf("child unavailable: %v", err))
		return
	}

	// WebSocket upgrade → dedicated proxy path.
	if suffix == "/watch" && isWebSocketRequest(r) {
		p.proxyWebSocket(w, r, child, key)
		return
	}

	p.proxyHTTP(w, r, child, key, suffix)
}

// hasTraversal reports whether a decoded path is a directory-traversal attempt.
// A path is hostile if either:
//   - any "/"-delimited segment is exactly ".." (catches the dangerous
//     /{matched-route}/../../ suffix form that path.Clean would otherwise
//     resolve away before inspection), or
//   - path.Clean(p) != p, i.e. p was not already in canonical form (catches
//     "." segments, doubled slashes, and any other non-canonical shape that
//     could be reinterpreted downstream).
//
// It deliberately does NOT call strings.Contains(path.Clean(p), "..") — Clean
// removes ".." segments, so that test almost never fires.
func hasTraversal(p string) bool {
	for _, seg := range strings.Split(p, "/") {
		if seg == ".." {
			return true
		}
	}
	// A single trailing slash is a legitimate request shape (trailing-slash
	// variants must proxy normally), and path.Clean strips it — so compare
	// against the trailing slash trimmed to avoid a false positive there.
	canonical := strings.TrimSuffix(p, "/")
	if canonical == "" {
		canonical = "/"
	}
	if path.Clean(p) != canonical {
		return true
	}
	return false
}

// splitKeyFromPath splits a URL path of the form /{project}/{file}[/rest] into
// key="project/file" and suffix="/rest" (empty string if no rest).
// Returns ("", "") if the path has fewer than two path segments.
func splitKeyFromPath(urlPath string) (key, suffix string) {
	trimmed := strings.TrimPrefix(urlPath, "/")
	parts := strings.SplitN(trimmed, "/", 3)
	if len(parts) < 2 || parts[0] == "" || parts[1] == "" {
		return "", ""
	}
	key = parts[0] + "/" + parts[1]
	if len(parts) == 3 {
		suffix = "/" + parts[2]
	}
	return key, suffix
}

// isWebSocketRequest reports whether r carries a WebSocket upgrade header.
func isWebSocketRequest(r *http.Request) bool {
	return strings.EqualFold(r.Header.Get("Upgrade"), "websocket") &&
		strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade")
}

// writeJSONErr writes a JSON {"error":"..."} response with the given status code.
func writeJSONErr(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	json.NewEncoder(w).Encode(map[string]string{"error": msg}) //nolint:errcheck
}

// ── HTTP proxy ────────────────────────────────────────────────────────────────

// proxyHTTP reverse-proxies a plain HTTP request to the child process.
// suffix is the sub-path to forward to the child (empty string → "/").
// For text/html it rewrites /static/ → /{key}/static/.
// For /static/watch.js it rewrites the ws:// literal.
// All other responses stream unmodified (no buffering).
func (p *ProxyHandler) proxyHTTP(w http.ResponseWriter, r *http.Request, child *Child, key, suffix string) {
	target := &url.URL{
		Scheme: "http",
		Host:   fmt.Sprintf("127.0.0.1:%d", child.Port),
	}

	rp := &httputil.ReverseProxy{
		Director: func(req *http.Request) {
			req.URL.Scheme = target.Scheme
			req.URL.Host = target.Host
			if suffix == "" {
				req.URL.Path = "/"
			} else {
				req.URL.Path = suffix
			}
			req.URL.RawPath = ""
			req.URL.RawQuery = r.URL.RawQuery
			// Force identity encoding so rewrite logic sees plain text.
			req.Header.Set("Accept-Encoding", "identity")
			req.Host = target.Host
		},
		ModifyResponse: func(resp *http.Response) error {
			ct := resp.Header.Get("Content-Type")
			if strings.HasPrefix(ct, "text/html") {
				return p.rewriteHTML(resp, key)
			}
			if isWatchJSPath(suffix) {
				return p.rewriteWatchJS(resp, key)
			}
			return nil
		},
		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			log.Printf("proxy: %q: upstream error: %v", key, err)
			writeJSONErr(w, http.StatusBadGateway, fmt.Sprintf("upstream error: %v", err))
		},
	}

	rp.ServeHTTP(w, r)
}

// isWatchJSPath returns true when suffix is the watch.js asset path.
func isWatchJSPath(suffix string) bool {
	return suffix == "/static/watch.js"
}

// rewriteHTML buffers the HTML response body and replaces all occurrences of
// "/static/ with "/{key}/static/. On a miss it serves the body unmodified
// and emits a single warning per child.
func (p *ProxyHandler) rewriteHTML(resp *http.Response, key string) error {
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return err
	}

	old := []byte(htmlStaticOld)
	newPat := []byte(`"` + "/" + key + "/static/")

	if !bytes.Contains(body, old) {
		p.warnOnce(key, "html", fmt.Sprintf(
			"proxy: %q: HTML rewrite miss (%s): pattern %q not found — serving unmodified (d2 upgrade?)",
			key, probeVersion, htmlStaticOld))
		resp.Body = io.NopCloser(bytes.NewReader(body))
		resp.ContentLength = -1
		resp.Header.Del("Content-Length")
		return nil
	}

	out := bytes.ReplaceAll(body, old, newPat)
	resp.Body = io.NopCloser(bytes.NewReader(out))
	resp.ContentLength = -1
	resp.Header.Del("Content-Length")
	resp.Header.Del("Content-Encoding")
	return nil
}

// rewriteWatchJS buffers watch.js and rewrites the ws:// template literal.
// d2 v0.7.1 pattern (with surrounding backticks):
//
//	`ws://${window.location.host}/watch`
//
// becomes:
//
//	`/{key}/watch`
//
// On a miss it serves the body unmodified and emits a single warning per child.
func (p *ProxyHandler) rewriteWatchJS(resp *http.Response, key string) error {
	body, err := io.ReadAll(resp.Body)
	resp.Body.Close()
	if err != nil {
		return err
	}

	old := []byte(watchJSOldPattern)
	newPat := []byte("`/" + key + "/watch`")

	if !bytes.Contains(body, old) {
		p.warnOnce(key, "watchjs", fmt.Sprintf(
			"proxy: %q: watch.js rewrite miss (%s): pattern %q not found — serving unmodified (d2 upgrade?)",
			key, probeVersion, watchJSOldPattern))
		resp.Body = io.NopCloser(bytes.NewReader(body))
		resp.ContentLength = -1
		resp.Header.Del("Content-Length")
		return nil
	}

	out := bytes.ReplaceAll(body, old, newPat)
	resp.Body = io.NopCloser(bytes.NewReader(out))
	resp.ContentLength = -1
	resp.Header.Del("Content-Length")
	resp.Header.Del("Content-Encoding")
	return nil
}

// warnOnce logs msg at most once per (key, warnType) pair per daemon lifetime.
func (p *ProxyHandler) warnOnce(key, warnType, msg string) {
	mapKey := key + "\x00" + warnType
	p.mu.Lock()
	already := p.rewriteWarned[mapKey]
	if !already {
		p.rewriteWarned[mapKey] = true
	}
	p.mu.Unlock()
	if !already {
		log.Print(msg)
	}
}

// ── WebSocket proxy ───────────────────────────────────────────────────────────

// proxyWebSocket upgrades the inbound connection and bidirectionally proxies
// WebSocket frames to/from the child's /watch endpoint.
// AddClient is called on connect; RemoveClient on close — the client count
// gates the idle reaper.
func (p *ProxyHandler) proxyWebSocket(w http.ResponseWriter, r *http.Request, child *Child, key string) {
	backendAddr := fmt.Sprintf("127.0.0.1:%d", child.Port)

	// Dial the backend and complete its WS handshake.
	backendConn, err := dialBackendWS(backendAddr, r.Header.Get("Sec-WebSocket-Key"))
	if err != nil {
		log.Printf("proxy: ws %q: backend dial: %v", key, err)
		writeJSONErr(w, http.StatusBadGateway, fmt.Sprintf("ws backend unavailable: %v", err))
		return
	}
	defer backendConn.Close()

	// Hijack the inbound client connection.
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "hijack not supported", http.StatusInternalServerError)
		return
	}
	clientConn, clientBuf, err := hj.Hijack()
	if err != nil {
		log.Printf("proxy: ws %q: hijack: %v", key, err)
		return
	}
	defer clientConn.Close()

	// Send 101 Switching Protocols to the client.
	accept := wsAccept(r.Header.Get("Sec-WebSocket-Key"))
	fmt.Fprintf(clientConn,
		"HTTP/1.1 101 Switching Protocols\r\n"+
			"Upgrade: websocket\r\n"+
			"Connection: Upgrade\r\n"+
			"Sec-WebSocket-Accept: %s\r\n\r\n",
		accept)

	// Track active client count for the reaper.
	p.cm.AddClient(key)
	defer p.cm.RemoveClient(key)

	// Bidirectional frame relay.
	done := make(chan struct{}, 2)
	go func() {
		// clientBuf may have buffered data from the hijacked connection.
		io.Copy(backendConn, clientBuf) //nolint:errcheck
		done <- struct{}{}
	}()
	go func() {
		io.Copy(clientConn, backendConn) //nolint:errcheck
		done <- struct{}{}
	}()
	<-done
}

// dialBackendWS opens a TCP connection to backendAddr, sends an HTTP/1.1
// WebSocket upgrade request for /watch, and reads back the 101 header.
// Returns the open connection (positioned after the 101 headers) on success.
func dialBackendWS(backendAddr, wsKey string) (net.Conn, error) {
	conn, err := net.Dial("tcp", backendAddr)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", backendAddr, err)
	}

	fmt.Fprintf(conn,
		"GET /watch HTTP/1.1\r\n"+
			"Host: %s\r\n"+
			"Upgrade: websocket\r\n"+
			"Connection: Upgrade\r\n"+
			"Sec-WebSocket-Key: %s\r\n"+
			"Sec-WebSocket-Version: 13\r\n\r\n",
		backendAddr, wsKey)

	// Read until end of HTTP headers (\r\n\r\n).
	buf := make([]byte, 1024)
	total := 0
	for total < len(buf) {
		n, err := conn.Read(buf[total:])
		if err != nil {
			conn.Close()
			return nil, fmt.Errorf("read 101: %w", err)
		}
		total += n
		if bytes.Contains(buf[:total], []byte("\r\n\r\n")) {
			break
		}
	}
	resp := string(buf[:total])
	if !strings.Contains(resp, "101") {
		conn.Close()
		return nil, fmt.Errorf("backend did not 101: %q", resp[:min(80, len(resp))])
	}
	return conn, nil
}

// wsAccept computes the Sec-WebSocket-Accept value for a given key (RFC 6455).
func wsAccept(key string) string {
	const guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
	h := sha1.New()
	h.Write([]byte(key + guid))
	return base64.StdEncoding.EncodeToString(h.Sum(nil))
}

// min returns the smaller of a and b.
func min(a, b int) int {
	if a < b {
		return a
	}
	return b
}
