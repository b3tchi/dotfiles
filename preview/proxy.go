package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strconv"
	"sync"
	"time"
)

// openTimeout bounds the nvim --remote subprocess so a dead/unreachable
// nvim server can't stall the request goroutine indefinitely (sp008 Task 6
// edge case: "nvim server dead -> error, not a hang"; sp008 plan
// anti-pattern: never block a request goroutine unbounded).
const openTimeout = 3 * time.Second

// handleOpen serves POST /open {"path": "...", "slot": N?} — the reverse
// channel (ft005 api_surface /open, sp008 Task 6): the webview asks the
// daemon to open a file back in a running nvim instance via
// "nvim --server <addr> --remote <path>".
//
// slot is optional (sp009 Task 2, back-compat with sp008 Task 6): when
// present, the target address comes from SlotManager.NvimAddr(slot) — the
// per-slot registry sp009 Task 1 built — so a multi-window setup opens the
// file back in the SPECIFIC nvim that owns that /preview<N> slot rather
// than whichever nvim happened to set the global $NVIM. When slot is
// absent, behavior is unchanged from sp008: the global os.Getenv("NVIM").
//
// Validation runs strictly before any subprocess exec, in this order:
//  1. decode the JSON body (malformed -> 400, never reaches the next step)
//  2. resolveInRoot (path.go, sp008 Task 2) — the path must exist AND
//     resolve inside the allowed root; an escape is 400, a missing path is
//  404. This is the sp008 Task 6 anti-pattern gate: no raw webview input
//     reaches a subprocess unvalidated.
//  3. a target nvim address must be resolvable — either the slot's
//     registered addr (slot present) or $NVIM (slot absent). With nothing
//     to drive, a missing target must be a distinct, visible error (424
//     Failed Dependency), not a silent no-op (sp008 Task 6 / sp009 Task 2
//     success criteria) — and this must never fall back to the OTHER
//     source (a slot present but unbound must NOT silently use $NVIM).
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
		Slot *int   `json:"slot"`
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

	var nvimServer string
	if body.Slot != nil {
		nvimServer = s.slots.NvimAddr(*body.Slot)
		if nvimServer == "" {
			http.Error(w, "no nvim registered for this slot", http.StatusFailedDependency)
			return
		}
	} else {
		nvimServer = os.Getenv("NVIM")
		if nvimServer == "" {
			http.Error(w, "no running nvim server ($NVIM unset)", http.StatusFailedDependency)
			return
		}
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

// ── akm/d2 iframe embed + lazy-spawn (sp008 Task 7; revised by adr0009) ─────
//
// BOTH akm zettels and .d2 files embed their backing daemon as a plain
// cross-origin <iframe> — renderAkmEmbed points at akm-graph, renderD2Embed
// at d2-router's resolved URL. preview-d proxies neither.
//
// sp008 Task 7 originally routed .d2 through a same-origin /d2embed/ proxy
// that stripped frame-blocking headers, because poc006 flagged d2-router's
// `d2 --watch` page as never run-tested for them. Running it finally
// (dotfiles-ars) settled both halves of that guess, in opposite directions:
// the page emits NO frame-blocking headers, so the proxy defended against
// nothing — while the proxy itself BROKE the embed. `d2 --watch` serves an
// empty #d2-svg-container and pushes the SVG over a websocket watch.js opens
// at a root-relative /{project}/{file}/watch, next to root-relative
// /{project}/{file}/static/* assets. Fronting only the document left both
// resolving against preview-d, which serves neither, so the diagram rendered
// blank with no error at all.
//
// Proxying the document alone cannot work, and proxying the rest would mean
// carrying d2-router's whole asset + websocket surface — exactly what
// poc006 warned against. The origin has to be d2-router's own. See adr0009.

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

// highlightForwardTimeout bounds forwardAkmHighlight's POST to akm-graph-d
// so a dead/unresponsive daemon can't stall the /preview<N> request
// goroutine indefinitely — the sp009 handleOpen scoped-client discipline
// applied to an HTTP forward instead of an nvim subprocess (sp011 Task 3
// success criteria: "scoped-timeout client, the sp009 /open pattern").
const highlightForwardTimeout = 2 * time.Second

// forwardAkmHighlight POSTs {"path":path,"slot":slot} to akm-graph-d's
// POST /api/highlight (ft004 api_surface, sp011 Task 1) so the embedded
// viewer can mark the new current zettel without preview-d reloading the
// iframe (sp011 solution). path must already be root-relative — the same
// canonicalized string handlePreviewSet stores as the slot's current path
// — since akm-graph-d resolves it against its own in-process graph
// (trusted-map direction, mirroring /api/open's id -> path lookup in
// reverse; sp011 Task 3 anti-pattern: never trust a client-sent id).
//
// Any failure — daemon down (connection refused), timeout, or a non-2xx
// status — is returned as a plain error and never panics. The caller
// (handlePreviewSet) decides what a failure means for the broadcast
// decision; this function's only job is "did the forward succeed" (sp011
// Task 3 success criteria: highlight POST failure on an akm->akm
// transition falls back to broadcasting the redraw frame, never a dead
// preview).
func forwardAkmHighlight(path string, slot int) error {
	body, err := json.Marshal(map[string]any{"path": path, "slot": slot})
	if err != nil {
		return err
	}
	client := http.Client{Timeout: highlightForwardTimeout}
	resp, err := client.Post(
		"http://127.0.0.1:"+akmGraphPort()+"/api/highlight",
		"application/json",
		bytes.NewReader(body),
	)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return fmt.Errorf("akm-graph highlight: status %d", resp.StatusCode)
	}
	return nil
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
//
// slot is sp009 Task 6's addition: when the /preview<N> shell loaded this
// /file/<path> with ?slot=N (handleFile's parseSlotQuery), that N is
// threaded onto the akm-graph iframe's own src as ?slot=N, so a click inside
// the embedded graph carries the window's slot back through /open (T2's
// handleOpen routing). nil (no ?slot on the request — e.g. a standalone
// /file/<path> visited directly) omits the param entirely, matching
// pre-sp009 behavior exactly (back-compat).
func renderAkmEmbed(w http.ResponseWriter, root string, slot *int) {
	if err := ensureAkmGraphRunning(root); err != nil {
		renderBackendUnavailable(w, "akm-graph", err)
		return
	}
	src := "http://127.0.0.1:" + akmGraphPort() + "/"
	if slot != nil {
		src = appendSlotQuery(src, *slot)
	}
	writeIframeEmbed(w, src)
}

// appendSlotQuery appends ?slot=N (or &slot=N, correctly, if src already
// carries a query string) to src. Parsed/re-encoded through net/url rather
// than naive string concatenation so this stays correct if src ever gains
// its own query params (sp009 Task 6 edge case: akm path that already
// carries a query -> slot appended correctly, not double "?").
func appendSlotQuery(src string, slot int) string {
	u, err := url.Parse(src)
	if err != nil {
		return src
	}
	q := u.Query()
	q.Set("slot", strconv.Itoa(slot))
	u.RawQuery = q.Encode()
	return u.String()
}

// renderD2Embed serves the /file/<path> response for a .d2 file: a page
// embedding an <iframe> pointed DIRECTLY at d2-router's own resolved URL,
// the same plain cross-origin embed renderAkmEmbed uses (adr0009).
//
// The origin is the whole point. `d2 --watch` serves an empty
// #d2-svg-container and pushes the SVG over a websocket watch.js opens at a
// root-relative /{project}/{file}/watch, alongside root-relative
// /{project}/{file}/static/* assets. Every one of those resolves against the
// iframe's own origin, so only d2-router can answer them. Fronting the
// document with a preview-d proxy left the assets and the socket pointed at
// preview-d, which served neither — the page loaded and the diagram rendered
// blank, with no error anywhere (dotfiles-ars).
//
// absPath must be the already-root-validated filesystem path (handleFile
// resolves it through resolveInRoot before dispatching here), since it is
// handed straight to d2-router's /api/resolve.
func renderD2Embed(w http.ResponseWriter, absPath string) {
	if err := ensureD2RouterRunning(); err != nil {
		renderBackendUnavailable(w, "d2-router", err)
		return
	}
	src, err := resolveD2URL(absPath)
	if err != nil {
		renderBackendUnavailable(w, "d2-router", err)
		return
	}
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
