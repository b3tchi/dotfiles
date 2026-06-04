package main

import (
	"bytes"
	"crypto/sha1"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"path"
	"strings"
	"sync"
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
	cm  *ChildManager

	// rewriteWarned tracks (key, rewriteType) pairs that have already logged
	// a warning so we emit at most one warning per child per type per daemon lifetime.
	mu            sync.Mutex
	rewriteWarned map[string]bool

	// routeOnce guards both route caches.
	routeOnce sync.Once
	// routeByRaw: route (URL-encoded, as stored in Index) → RouteEntry.
	routeByRaw map[string]RouteEntry
	// routeByDecoded: URL-decoded route → RouteEntry (for Go HTTP's pre-decoded r.URL.Path).
	routeByDecoded map[string]RouteEntry
}

// NewProxyHandler creates a ProxyHandler backed by the given index and child manager.
func NewProxyHandler(idx *IndexData, cm *ChildManager) *ProxyHandler {
	return &ProxyHandler{
		idx:           idx,
		cm:            cm,
		rewriteWarned: make(map[string]bool),
	}
}

// buildRoutes initialises both route caches on first call.
func (p *ProxyHandler) buildRoutes() {
	p.routeOnce.Do(func() {
		p.routeByRaw = make(map[string]RouteEntry, len(p.idx.Entries))
		p.routeByDecoded = make(map[string]RouteEntry, len(p.idx.Entries))
		for _, e := range p.idx.Entries {
			p.routeByRaw[e.Route] = e
			if decoded, err := url.PathUnescape(e.Route); err == nil {
				p.routeByDecoded[decoded] = e
			}
		}
	})
}

// lookupRoute finds a RouteEntry for a request path.
// Go's HTTP server pre-decodes r.URL.Path, so we check the decoded map first,
// then fall back to the raw map.
func (p *ProxyHandler) lookupRoute(reqPath string) (RouteEntry, bool) {
	p.buildRoutes()
	// Check decoded map first (covers Go HTTP server's pre-decoded paths).
	if e, ok := p.routeByDecoded[reqPath]; ok {
		return e, true
	}
	// Fall back to raw map (covers paths passed directly, e.g. in tests).
	e, ok := p.routeByRaw[reqPath]
	return e, ok
}

// ServeHTTP handles all requests matching /{project}/{file}[/...].
func (p *ProxyHandler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Reject path traversal before any routing (raw and decoded).
	decodedPath := r.URL.Path
	if strings.Contains(path.Clean(decodedPath), "..") {
		writeJSONErr(w, http.StatusBadRequest, "path traversal rejected")
		return
	}
	if r.URL.RawPath != "" {
		if decoded, err := url.PathUnescape(r.URL.RawPath); err == nil {
			if strings.Contains(path.Clean(decoded), "..") {
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
