package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// openTimeout bounds the nvim --remote subprocess so a dead/unreachable
// nvim server can't stall the request goroutine indefinitely (sp008 Task 6
// edge case: "nvim server dead -> error, not a hang"; sp008 plan
// anti-pattern: never block a request goroutine unbounded).
const openTimeout = 3 * time.Second

// handleOpen serves POST /open {"path": "..."} — the reverse channel (ft005
// api_surface /open, sp008 Task 6): the webview asks the daemon to open a
// file back in the running nvim instance via
// "nvim --server $NVIM --remote <path>".
//
// Validation runs strictly before any subprocess exec, in this order:
//  1. decode the JSON body (malformed -> 400, never reaches the next step)
//  2. resolveInRoot (path.go, sp008 Task 2) — the path must exist AND
//     resolve inside the allowed root; an escape is 400, a missing path is
//  404. This is the sp008 Task 6 anti-pattern gate: no raw webview input
//     reaches a subprocess unvalidated.
//  3. $NVIM must be set — with no running nvim server there is nothing to
//     drive, and a missing target must be a distinct, visible error (424
//     Failed Dependency), not a silent no-op (sp008 Task 6 success
//     criteria).
//
// Only once all three hold does exec.CommandContext run, and it runs with
// an explicit arg vector ("nvim", "--server", <addr>, "--remote", <path>)
// under a bounded context — never a shell string, never unbounded (sp008
// Task 6 edge cases: path with spaces/special chars passed safely; nvim
// server dead -> error not hang).
func (s *Server) handleOpen(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodPost) {
		return
	}
	defer r.Body.Close()

	var body struct {
		Path string `json:"path"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		http.Error(w, "bad request body", http.StatusBadRequest)
		return
	}

	resolved, err := resolveInRoot(s.root, body.Path)
	if err != nil {
		switch {
		case errors.Is(err, ErrPathEscape):
			http.Error(w, "bad path", http.StatusBadRequest)
		case errors.Is(err, os.ErrNotExist):
			http.Error(w, "not found", http.StatusNotFound)
		default:
			http.Error(w, "internal error", http.StatusInternalServerError)
		}
		return
	}

	nvimServer := os.Getenv("NVIM")
	if nvimServer == "" {
		http.Error(w, "no running nvim server ($NVIM unset)", http.StatusFailedDependency)
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), openTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "nvim", "--server", nvimServer, "--remote", resolved)
	if err := cmd.Run(); err != nil {
		http.Error(w, "failed to open in nvim: "+err.Error(), http.StatusFailedDependency)
		return
	}

	writeJSON(w, map[string]any{"opened": resolved})
}

// ── sp008 Task 7: akm/d2 iframe embed + lazy-spawn ──────────────────────────
//
// akm zettels embed [[ft004]] (akm-graph) as a genuine cross-origin
// <iframe> — poc006 confirmed akm-graph emits zero frame-blocking headers,
// so a direct browser-to-daemon iframe is safe and needs no proxying
// (renderAkmEmbed below).
//
// .d2 files instead route their iframe src through THIS daemon's own
// /d2embed/ route (handleD2Embed), which reverse-proxies exactly one d2-
// router page response and strips any frame-blocking header — poc006
// flagged d2-router's proxied `d2 --watch` page as not run-tested for this,
// so preview-d defends against it directly rather than assuming ft002
// already does (renderD2Embed / handleD2Embed / proxyAndStripFrameHeaders
// below). This is deliberately NOT a general path-prefix reverse proxy of
// d2-router's whole asset/websocket surface (poc006's explicit
// recommendation) — just this one top-level document.

// daemonHealthTimeout bounds a single /api/status health probe so a
// half-dead daemon (accepting TCP but never responding) can't stall a
// health check indefinitely.
const daemonHealthTimeout = 500 * time.Millisecond

// daemonSpawnWait/daemonSpawnPoll bound how long ensureDaemonRunning waits
// for a freshly-spawned daemon to answer /api/status, and how often it
// polls while waiting (sp008 Task 7 edge case: daemon slow to become
// healthy -> wait with timeout, never an unbounded block). Package-level
// vars (not consts) so tests can shorten them instead of paying the full
// production budget on every run — see TestEnsureDaemonRunningTimesOutWhenNeverHealthy.
var (
	daemonSpawnWait = 10 * time.Second
	daemonSpawnPoll = 150 * time.Millisecond
)

// daemonError distinguishes a lazy-spawn/health failure ("binary not found",
// "never became healthy") from a generic error, so callers building the
// backend-unavailable preview can show the daemon's name without needing to
// pass it separately. Its Error() message already includes enough context
// for renderBackendUnavailable to print directly.
type daemonError struct{ msg string }

func (e *daemonError) Error() string { return e.msg }

// daemonHealthy reports whether a daemon listening on 127.0.0.1:port
// answers GET /api/status with 200 within daemonHealthTimeout (ft002/ft004
// api_surface parity: both real daemons expose /api/status).
func daemonHealthy(port string) bool {
	client := http.Client{Timeout: daemonHealthTimeout}
	resp, err := client.Get("http://127.0.0.1:" + port + "/api/status")
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	return resp.StatusCode == http.StatusOK
}

// ensureDaemonRunning lazy-spawns a daemon at port via spawn if it isn't
// already answering /api/status, then waits (bounded by daemonSpawnWait)
// for it to become healthy. mu serializes concurrent callers targeting the
// SAME daemon via double-checked locking: health is probed once before
// acquiring mu (fast path, no lock contention once the daemon is up) and
// again immediately after acquiring it — a caller that lost the race to
// another goroutine's spawn (which may have completed while this caller
// waited for the lock) observes the now-healthy daemon there and returns
// without spawning a second time (sp008 Task 7 edge case: spawn race — two
// requests needing the daemon at once produce a SINGLE spawn, not two).
func ensureDaemonRunning(mu *sync.Mutex, port string, spawn func() error) error {
	if daemonHealthy(port) {
		return nil
	}
	mu.Lock()
	defer mu.Unlock()
	if daemonHealthy(port) {
		return nil
	}
	if err := spawn(); err != nil {
		return err
	}
	deadline := time.Now().Add(daemonSpawnWait)
	for time.Now().Before(deadline) {
		if daemonHealthy(port) {
			return nil
		}
		time.Sleep(daemonSpawnPoll)
	}
	return &daemonError{msg: fmt.Sprintf("daemon on port %s did not become healthy within %s", port, daemonSpawnWait)}
}

// frameProxyTimeout bounds proxyAndStripFrameHeaders' single upstream fetch
// so an unreachable/hanging daemon can't stall the request goroutine
// indefinitely (sp008 plan anti-pattern: external calls MUST carry a
// timeout).
const frameProxyTimeout = 5 * time.Second

// frameBlockingHeaders lists response headers that would prevent embedded
// content from rendering inside our iframe. Matched case-insensitively
// (net/http header keys are already canonicalized, but the match helper
// stays defensive) and stripped unconditionally from any proxied upstream
// response (poc006 residual; sp008 Task 7 success criteria).
var frameBlockingHeaders = []string{"X-Frame-Options", "Content-Security-Policy"}

func isFrameBlockingHeader(name string) bool {
	for _, h := range frameBlockingHeaders {
		if strings.EqualFold(h, name) {
			return true
		}
	}
	return false
}

// proxyAndStripFrameHeaders fetches target and copies its status, headers
// (minus frameBlockingHeaders), and body verbatim to w — a single-hop proxy
// for exactly one page response. An unreachable/erroring upstream degrades
// to renderBackendUnavailable's safe 200 page rather than a raw 502 or a
// panic (sp008 Task 7 edge case: target daemon unavailable -> a graceful
// preview, not a broken iframe).
func proxyAndStripFrameHeaders(w http.ResponseWriter, target string) {
	client := http.Client{Timeout: frameProxyTimeout}
	resp, err := client.Get(target)
	if err != nil {
		renderBackendUnavailable(w, "d2-router", err)
		return
	}
	defer resp.Body.Close()

	for k, vv := range resp.Header {
		if isFrameBlockingHeader(k) {
			continue
		}
		for _, v := range vv {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(w, resp.Body)
}

// renderBackendUnavailable serves a safe "backend unavailable" HTML page —
// always 200, matching render.go's renderFallback idiom of never emitting a
// 500/502 for a problem that isn't the requesting client's fault (sp008
// Task 7 edge case: target daemon binary absent / unreachable -> a clear
// preview, not a broken iframe pointing at a dead origin).
func renderBackendUnavailable(w http.ResponseWriter, name string, cause error) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html><html><head><meta charset="utf-8"></head>`+
		`<body class="preview-fallback"><p>%s backend unavailable: %s</p></body></html>`,
		html.EscapeString(name), html.EscapeString(cause.Error()))
}

// akmGraphPort/d2RouterPort resolve each daemon's port from the SAME env
// vars their own nu wrappers read (nushell/actions/akm-graph's graph-port,
// nushell/actions/d2-router's router-port) so a user's existing
// $AKM_GRAPH_PORT / $D2_ROUTER_PORT override is honoured consistently
// whether the daemon was already running or preview-d just spawned it
// (spawnDaemonBinary inherits the same process env by default).
func akmGraphPort() string {
	if p := os.Getenv("AKM_GRAPH_PORT"); p != "" {
		return p
	}
	return "4810"
}

func d2RouterPort() string {
	if p := os.Getenv("D2_ROUTER_PORT"); p != "" {
		return p
	}
	return "4800"
}

// akmSpawnMu/d2SpawnMu are the per-daemon locks ensureDaemonRunning uses to
// collapse concurrent spawn attempts into one (sp008 Task 7 edge case:
// spawn race). Package-level and shared across all requests targeting the
// same preview-d process — exactly the scope needed, since the race is
// "two requests in the SAME process both find the daemon down".
var akmSpawnMu, d2SpawnMu sync.Mutex

// akmGraphSpawn launches akm-graph-d (ft004) with --root pointed at the
// SAME root preview-d itself is jailed to, matching nushell/actions/
// akm-graph's own launch args. A package-level var (not a plain function)
// so tests can substitute a spy in place of a real OS subprocess (sp008
// Task 7 test_plan: "spy on the spawn") without requiring an actual
// akm-graph-d binary on PATH.
var akmGraphSpawn = func(root string) error {
	return spawnDaemonBinary("akm-graph-d", "--root", root)
}

// d2RouterSpawn launches d2-router-d (ft002) with no args, matching
// nushell/actions/d2-router's own launch (its registry/routing comes from
// [[ft001]], not a --root flag). Same test-seam rationale as akmGraphSpawn.
var d2RouterSpawn = func() error {
	return spawnDaemonBinary("d2-router-d")
}

// spawnDaemonBinary starts bin (with args) as a detached background
// process. A binary missing from PATH is reported as a distinct
// *daemonError before any exec attempt (sp008 Task 7 edge case: target
// daemon binary absent -> a clear, distinguishable error, not a generic
// exec failure). The spawned process is reaped via a background Wait() so
// it never lingers as a zombie; its exit status is otherwise unused —
// preview-d doesn't own these daemons' lifecycle beyond bootstrapping them,
// same as the nu wrappers' own detached nohup launch.
func spawnDaemonBinary(bin string, args ...string) error {
	if _, err := exec.LookPath(bin); err != nil {
		return &daemonError{msg: bin + ": not found on PATH"}
	}
	cmd := exec.Command(bin, args...)
	if err := cmd.Start(); err != nil {
		return &daemonError{msg: "failed to start " + bin + ": " + err.Error()}
	}
	go func() { _ = cmd.Wait() }()
	return nil
}

// ensureAkmGraphRunning/ensureD2RouterRunning bind ensureDaemonRunning's
// generic lazy-spawn+health-wait to each daemon's specific port/spawn/lock.
func ensureAkmGraphRunning(root string) error {
	return ensureDaemonRunning(&akmSpawnMu, akmGraphPort(), func() error { return akmGraphSpawn(root) })
}

func ensureD2RouterRunning() error {
	return ensureDaemonRunning(&d2SpawnMu, d2RouterPort(), func() error { return d2RouterSpawn() })
}

// renderAkmEmbed serves the /file/<path> response for an akm zettel: a page
// embedding a genuine cross-origin <iframe> pointing directly at akm-graph's
// whole-graph viewer (ft004 GET /). poc006 validated akm-graph emits zero
// frame-blocking headers, so unlike the d2 case below, no proxying is
// needed — the browser talks to akm-graph:port directly (sp008 Task 7
// success criteria).
func renderAkmEmbed(w http.ResponseWriter, root string) {
	if err := ensureAkmGraphRunning(root); err != nil {
		renderBackendUnavailable(w, "akm-graph", err)
		return
	}
	writeIframeEmbed(w, "http://127.0.0.1:"+akmGraphPort()+"/")
}

// renderD2Embed serves the /file/<path> response for a .d2 file: a page
// embedding an <iframe> whose src is preview-d's OWN /d2embed/<reqPath>
// route (handleD2Embed below) rather than a direct cross-origin link to
// d2-router. This is the poc006-flagged difference from the akm case: since
// d2-router's proxied `d2 --watch` page headers were never run-tested,
// preview-d proxies that one page itself so it can strip a frame-blocking
// header if one ever appears (sp008 Task 7 success criteria).
func renderD2Embed(w http.ResponseWriter, reqPath string) {
	if err := ensureD2RouterRunning(); err != nil {
		renderBackendUnavailable(w, "d2-router", err)
		return
	}
	src := (&url.URL{Path: "/d2embed/" + reqPath}).String()
	writeIframeEmbed(w, src)
}

// writeIframeEmbed serves a minimal full-viewport HTML wrapper embedding an
// <iframe> at src — shared by renderAkmEmbed and renderD2Embed, the only
// difference between them being whether src is cross-origin (akm) or a
// preview-d-owned proxy route (d2).
func writeIframeEmbed(w http.ResponseWriter, src string) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	fmt.Fprintf(w, `<!DOCTYPE html><html><head><meta charset="utf-8"></head>`+
		`<body class="preview-embed" style="margin:0">`+
		`<iframe src="%s" style="position:fixed;inset:0;width:100%%;height:100%%;border:0" title="embedded preview"></iframe>`+
		`</body></html>`,
		html.EscapeString(src))
}

// handleD2Embed serves GET /d2embed/<path> — the same-origin proxy target
// renderD2Embed's iframe points at. It re-validates path through
// resolveInRoot rather than trusting the iframe src as pre-validated (sp008
// Task 2 anti-pattern: no raw webview input reaches network I/O
// unvalidated), ensures d2-router is running, resolves the absolute path to
// a routed URL via ft002's GET /api/resolve, and proxies that ONE response
// with frame-blocking headers stripped (proxyAndStripFrameHeaders). A path
// this daemon doesn't recognise (resolveD2URL failing, e.g. resolve's own
// 404 for a file outside every registered project) degrades to the same
// backend-unavailable preview as a fully-down daemon — a simplification of
// the sp008 Task 7 edge case "its own 404 shown in iframe": preview-d always
// surfaces SOMETHING legible inside the iframe rather than a bare network
// error, even though it doesn't replicate d2-router's exact 404 body.
func (s *Server) handleD2Embed(w http.ResponseWriter, r *http.Request) {
	if !requireMethod(w, r, http.MethodGet) {
		return
	}
	reqPath := strings.TrimPrefix(r.URL.Path, "/d2embed/")
	resolved, err := resolveInRoot(s.root, reqPath)
	if err != nil {
		switch {
		case errors.Is(err, ErrPathEscape):
			http.Error(w, "bad path", http.StatusBadRequest)
		case errors.Is(err, os.ErrNotExist):
			http.Error(w, "not found", http.StatusNotFound)
		default:
			http.Error(w, "internal error", http.StatusInternalServerError)
		}
		return
	}

	if err := ensureD2RouterRunning(); err != nil {
		renderBackendUnavailable(w, "d2-router", err)
		return
	}

	target, err := resolveD2URL(resolved)
	if err != nil {
		renderBackendUnavailable(w, "d2-router", err)
		return
	}
	proxyAndStripFrameHeaders(w, target)
}

// resolveD2URL asks the (already-healthy) d2-router daemon which URL serves
// absPath, via ft002's GET /api/resolve?path=<abs> (ft002 api_surface:
// "map an absolute file path to its route"). Bounded by daemonHealthTimeout
// — this is a single fast local API call, not a page render.
func resolveD2URL(absPath string) (string, error) {
	client := http.Client{Timeout: daemonHealthTimeout}
	q := url.Values{"path": {absPath}}
	resp, err := client.Get("http://127.0.0.1:" + d2RouterPort() + "/api/resolve?" + q.Encode())
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("d2-router resolve: status %d", resp.StatusCode)
	}
	var body struct {
		URL string `json:"url"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		return "", err
	}
	return body.URL, nil
}
