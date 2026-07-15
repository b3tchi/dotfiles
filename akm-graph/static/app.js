// akm-graph viewer — app.js
//
// Pluggable render backend: the data/legend/filter/tooltip/isolate/label layer is
// backend-agnostic and drives ONE adapter interface. Two adapters ship:
//   • cosmos      — cosmos.gl WebGL renderer (cosmos-bundle.js, ES module)
//   • force-graph — Vasturiano force-graph 2D canvas (force-graph-bundle.js, UMD)
// Backend is chosen by ?backend=force-graph|cosmos (default force-graph, or the
// <meta name="akm-backend"> the server injects). force-graph is the default: for
// a ~100s-node 2D graph, WebGL is overkill and its per-frame GPU readback +
// always-on render loop keep the GPU hot at idle. The 2D canvas backend parks
// both its layout engine and its render loop when idle → cold GPU.
//
// Adapter contract (see makeCosmosBackend / makeForceGraphBackend):
//   init(rootEl, opts)              construct engine + wire events
//   setData(nodes, links)           push data, (re)heat layout
//   refresh()                       re-evaluate color/size accessors, NO relayout
//   forEachScreenPos(cb)            cb(id, screenX, screenY) for every node
//   isMoving() -> bool              layout still settling? (drives the label loop)
//
// Graph JSON: {nodes:[{id,type,status,alias,degree,ghost,archived}], links:[{source,target}]}

// ── Color palette — one distinct color per node type ──────────────────────────
// Authored as [r, g, b, a] in the 0–1 range for readability. Each backend
// converts to its own native form (cosmos: 0–255 RGB; force-graph: CSS string).
const TYPE_COLORS = {
  us:   [0.18, 0.60, 1.00, 1],   // blue      — user stories
  sp:   [0.50, 0.85, 0.50, 1],   // green     — specs
  im:   [0.95, 0.75, 0.20, 1],   // amber     — implementations
  ft:   [0.90, 0.50, 0.15, 1],   // orange    — features
  adr:  [0.75, 0.40, 0.90, 1],   // purple    — decisions
  cat:  [0.40, 0.80, 0.80, 1],   // teal      — categories
  pn:   [0.90, 0.65, 0.65, 1],   // pink      — personal notes
  poc:  [0.55, 0.85, 0.65, 1],   // mint      — proof-of-concepts
  hub:  [1.00, 0.85, 0.30, 1],   // yellow    — hub pages
  note: [0.60, 0.65, 0.70, 1],   // slate     — generic notes
};
const GHOST_COLOR   = [0.50, 0.50, 0.55, 0.55];  // gray, semi-transparent
const DEFAULT_COLOR = [0.65, 0.70, 0.75, 1.00];
const HIDDEN_COLOR  = [0, 0, 0, 0];              // fully transparent — toggled-off type
const LINK_RGBA     = [0.25, 0.30, 0.35, 0.6];
const LINK_HIDDEN   = [0, 0, 0, 0];              // link with a toggled-off endpoint disappears
const DIM_ALPHA     = 0.12;                       // greyout factor for non-selected nodes/links

// Human-readable legend names + display order for the category toggle panel.
const TYPE_LABELS = {
  us: "stories", sp: "specs", im: "impl", ft: "features", adr: "decisions",
  cat: "categories", poc: "pocs", pn: "personal", hub: "hubs", note: "notes",
};
const TYPE_ORDER = ["us", "sp", "im", "ft", "adr", "cat", "poc", "pn", "hub", "note"];

// ── Category toggle + selection state ────────────────────────────────────────
const activeTypes  = new Set();  // types currently visible
const knownTypes   = new Set();  // every type ever seen (so refreshes keep state)
let   showArchived = false;      // archived (retired) nodes hidden by default
let   selectedKeep = null;       // null = no isolate; else Set of kept ids (self+adjacent)

// ── Highlight state (sp011 ft004 Task 2, revised by Task 4) ─────────────────────
// Server-pushed "this is the zettel currently open in the editor" marker.
// Since Task 4 a highlight ALSO drives the isolate (setHighlight re-derives
// selectedKeep around it, last action wins vs manual click); the marker
// itself renders on the label pill only (nodeRGBA keeps the dot's type
// color). Two pieces of state:
//   storedHighlightId — last id received for OUR slot; kept even if the id
//                       doesn't (yet, or anymore) resolve against the live
//                       graph, so it survives a rebuild and re-resolves once
//                       the node reappears.
//   highlightId        — storedHighlightId resolved against the CURRENT
//                       graph (nodeIndex), or null if unresolved/absent.
//                       This is what the color/size accessors + label
//                       emphasis actually key off.
let storedHighlightId = null;
let highlightId       = null;

function isHighlighted(id) { return highlightId != null && id === highlightId; }

// Re-resolve storedHighlightId against the current nodeIndex. Called after
// every graph frame lands (rebuild may have dropped or restored the node) and
// after a fresh highlight message is stored.
function recomputeHighlight() {
  highlightId = (storedHighlightId && nodeIndex[storedHighlightId]) ? storedHighlightId : null;
}

function typeVisible(t) { return activeTypes.has(t); }
// A node is shown only when its type is active AND (it's not archived, or the
// archived toggle is on).
function nodeShown(n) { return n && activeTypes.has(n.type) && (showArchived || !n.archived); }

// Resolve a link endpoint (id string OR node object) to its node record.
function endpointNode(e) {
  if (e == null) return null;
  const id = (typeof e === "object" && e.id != null) ? e.id : e;
  return nodeIndex[id] || (typeof e === "object" ? e : null);
}
function endpointId(e) {
  if (e == null) return null;
  return (typeof e === "object" && e.id != null) ? e.id : e;
}

// ── Size by degree ─────────────────────────────────────────────────────────────
const MIN_SIZE  = 3;
const BASE_SIZE = 3;
const MAX_SIZE  = 10;
const SIZE_K    = 0.8;   // pixels per degree

function nodeSize(n) {
  if (!nodeShown(n)) return 0;   // toggled-off type: zero radius = gone + unhoverable
  const s = Math.min(BASE_SIZE + (n.degree || 0) * SIZE_K, MAX_SIZE);
  return n.ghost ? Math.max(s * 0.7, 2) : Math.max(s, MIN_SIZE);
}

// Canonical node color as [r,g,b,a] in 0–1. Gates on visibility + isolate state;
// the backend adapter converts this to its native color form. The highlighted
// node keeps its ORIGINAL type color and size — the current-zettel marker
// lives on the label pill only (user revision 2026-07-15: "don't highlight
// dot, keep original color, only highlight label"); the dot still escapes
// the isolate dim so it never fades while current.
function nodeRGBA(n) {
  if (!nodeShown(n)) return HIDDEN_COLOR;
  let c = n.ghost ? GHOST_COLOR : (TYPE_COLORS[n.type] || DEFAULT_COLOR);
  if (selectedKeep && !selectedKeep.has(n.id) && !isHighlighted(n.id)) c = [c[0], c[1], c[2], c[3] * DIM_ALPHA];
  return c;
}

// Canonical link color: vanishes if either endpoint is toggled off; dims if an
// isolate is active and the link isn't fully inside the kept neighborhood.
function linkRGBA(l) {
  const s = endpointNode(l && l.source);
  const t = endpointNode(l && l.target);
  if ((s && !nodeShown(s)) || (t && !nodeShown(t))) return LINK_HIDDEN;
  if (selectedKeep) {
    const sid = endpointId(l && l.source), tid = endpointId(l && l.target);
    if (!selectedKeep.has(sid) || !selectedKeep.has(tid)) {
      return [LINK_RGBA[0], LINK_RGBA[1], LINK_RGBA[2], LINK_RGBA[3] * DIM_ALPHA];
    }
  }
  return LINK_RGBA;
}

// CSS rgb() string for a node's type — used to tint its persistent label pill.
function cssColor(n) {
  const c = n.ghost ? GHOST_COLOR : (TYPE_COLORS[n.type] || DEFAULT_COLOR);
  return `rgb(${Math.round(c[0] * 255)}, ${Math.round(c[1] * 255)}, ${Math.round(c[2] * 255)})`;
}

// ── Persistent node labels (HTML overlay) ───────────────────────────────────────
// Neither backend draws text, so we render one HTML pill per node and sync it to
// the node's screen position while the graph moves (see the label loop below).
const labelsEl = document.getElementById("labels");
let labelEls = {};       // id → pill element
let labelRAF = null;

function buildLabels(nodes) {
  labelsEl.textContent = "";
  labelEls = {};
  for (const n of nodes) {
    const el = document.createElement("div");
    el.className = "node-label" + (n.ghost ? " ghost" : "");
    el.textContent = (n.alias && n.alias.trim()) ? n.alias : n.id;
    el.style.borderLeftColor = cssColor(n);
    el.style.transform = "translate(-9999px, -9999px)";  // off-screen until placed
    el.addEventListener("click", (e) => { e.stopPropagation(); selectNode(n.id); });
    labelsEl.appendChild(el);
    labelEls[n.id] = el;
  }
}

// ── Selection: isolate a node + its direct neighbors ────────────────────────────
// Backend-agnostic: compute the kept neighborhood from the link list, stash it in
// selectedKeep (the color accessors greyout everything else), then refresh the
// render + mirror the dim on the HTML labels.
function neighborsOf(id) {
  const keep = new Set([id]);
  for (const l of allLinks) {
    const s = endpointId(l.source), t = endpointId(l.target);
    if (s === id) keep.add(t);
    if (t === id) keep.add(s);
  }
  return keep;
}

// openSlot — the preview-d window slot this akm-graph iframe belongs to, read
// ONCE at bootstrap from ?slot= (sp009 Task 5), mirroring how ?fixture/?backend
// are read. When akm-graph is embedded in a preview-d window, ?slot names which
// nvim owns that window so a reverse-open lands in the right editor. Standalone
// (no ?slot) → null → the POST omits slot and preview-d falls back to its global
// $NVIM. A non-integer ?slot is treated as absent.
const openSlot = (() => {
  const raw = new URLSearchParams(window.location.search).get("slot");
  if (raw == null) return null;
  const n = Number.parseInt(raw, 10);
  return Number.isNaN(n) ? null : n;
})();

// requestOpen asks the akm daemon (POST /api/open) to reverse-open the clicked
// node's source file back in nvim (sp009 Task 5). Best-effort and fire-and-
// forget: the daemon resolves id→path and forwards to preview-d, but a failure
// (standalone akm-graph with no daemon route, preview-d down, ghost id → 404)
// must never disturb the client-side isolate. slot is included only when the
// page carried one, so a standalone view omits it entirely.
function requestOpen(id) {
  const body = openSlot == null ? { id } : { id, slot: openSlot };
  fetch("/api/open", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(body),
  }).catch(() => {});
}

// applyIsolate sets the isolate neighborhood (null = none) and repaints
// nodes + label dim state — the shared tail of selectNode/clearSelection
// and, since sp011 Task 4, setHighlight/renderData. Cursor highlight and
// manual click share selectedKeep deliberately: last action wins in both
// directions (the Task 4 user revision superseding Task 2's independence
// rule).
function applyIsolate(keep) {
  selectedKeep = keep;
  if (backend) backend.refresh();
  for (const [nid, el] of Object.entries(labelEls)) {
    el.classList.toggle("dim", keep ? !keep.has(nid) : false);
  }
  pumpLabels();
}

function selectNode(id) {
  if (!backend) return;
  requestOpen(id);
  applyIsolate(neighborsOf(id));
}

function clearSelection() {
  applyIsolate(null);
}

// ── Highlight rendering (sp011 ft004 Task 2) ────────────────────────────────────
// Toggle the "highlight" class on label pills to match the current
// highlightId. Safe to call any time (fresh labels after a rebuild, or a
// changed highlight against the same labels) — it's a pure resync, never
// touches selectedKeep/dim state.
function applyHighlightLabel() {
  for (const [nid, el] of Object.entries(labelEls)) {
    el.classList.toggle("highlight", nid === highlightId);
  }
}

// setHighlight is the single entry point for a highlight message meant for
// this viewer: store the id (possibly empty/null = clear), re-resolve against
// the live graph, then repaint. Since sp011 Task 4 it ALSO isolates the
// node's direct neighborhood — the same visual as clicking it, but WITHOUT
// selectNode's requestOpen side effect (that would bounce the editor on
// every cursor move). Empty/unknown id clears both the gold emphasis and
// the isolate. Still no camera motion.
function setHighlight(id) {
  storedHighlightId = id || null;
  recomputeHighlight();
  applyIsolate(highlightId != null ? neighborsOf(highlightId) : null);
  applyHighlightLabel();
}

// ── Category legend (type toggle) ───────────────────────────────────────────────
const legendEl = document.getElementById("legend");
let allNodes = [];
let allLinks = [];

function typesPresent(nodes) {
  const counts = {};
  for (const n of nodes) counts[n.type] = (counts[n.type] || 0) + 1;
  const seen = Object.keys(counts);
  const ordered = TYPE_ORDER.filter(t => t in counts)
    .concat(seen.filter(t => !TYPE_ORDER.includes(t)).sort());
  return ordered.map(t => ({ type: t, count: counts[t] }));
}

function buildLegend(nodes) {
  legendEl.textContent = "";
  // Archived toggle chip — first in the column, only when archived nodes exist.
  const archivedCount = nodes.filter(n => n.archived).length;
  if (archivedCount > 0) {
    const chip = document.createElement("div");
    chip.className = "legend-chip archived-chip" + (showArchived ? "" : " off");
    chip.title = "Show archived (retired) zettels";
    const swatch = document.createElement("span");
    swatch.className = "legend-swatch";
    swatch.style.background = "#8b949e";
    const name = document.createElement("span");
    name.className = "legend-name";
    name.textContent = "archived";
    const cnt = document.createElement("span");
    cnt.className = "legend-count";
    cnt.textContent = archivedCount;
    chip.append(swatch, name, cnt);
    chip.addEventListener("click", toggleArchived);
    legendEl.appendChild(chip);
  }
  for (const { type, count } of typesPresent(nodes)) {
    const chip = document.createElement("div");
    chip.className = "legend-chip" + (typeVisible(type) ? "" : " off");
    chip.dataset.type = type;
    const swatch = document.createElement("span");
    swatch.className = "legend-swatch";
    swatch.style.background = cssColor({ type });
    const name = document.createElement("span");
    name.className = "legend-name";
    name.textContent = TYPE_LABELS[type] || type;
    const cnt = document.createElement("span");
    cnt.className = "legend-count";
    cnt.textContent = count;
    chip.append(swatch, name, cnt);
    chip.addEventListener("click", () => toggleType(type));
    legendEl.appendChild(chip);
  }
}

// Show/hide the HTML label pills to match the current type filter.
function applyLabelVisibility() {
  for (const n of allNodes) {
    const el = labelEls[n.id];
    if (el) el.classList.toggle("hidden", !nodeShown(n));
  }
}

function toggleType(type) {
  if (activeTypes.has(type)) activeTypes.delete(type);
  else activeTypes.add(type);
  if (backend) backend.refresh();   // recompute color/size, freeze layout
  applyLabelVisibility();
  pumpLabels();
  const chip = legendEl.querySelector(`.legend-chip[data-type="${type}"]`);
  if (chip) chip.classList.toggle("off", !typeVisible(type));
}

function toggleArchived() {
  showArchived = !showArchived;
  if (backend) backend.refresh();
  applyLabelVisibility();
  pumpLabels();
  const chip = legendEl.querySelector(".archived-chip");
  if (chip) chip.classList.toggle("off", !showArchived);
}

// ── Label loop ──────────────────────────────────────────────────────────────────
// syncLabels does ONE projection pass. positionLabels is self-terminating: it
// reschedules only while the layout is still moving, so at idle the loop parks and
// does no per-frame work. pumpLabels wakes it for a single frame; a live gesture
// keeps calling pumpLabels (via the backend's per-transform zoom event) so labels
// track the camera without a sticky "is-panning" flag that could get stuck on.
function syncLabels() {
  if (!backend) return;
  backend.forEachScreenPos((id, x, y) => {
    const el = labelEls[id];
    if (!el) return;
    el.style.transform =
      `translate(${Math.round(x)}px, ${Math.round(y)}px) translate(-50%, -190%)`;
  });
}

function positionLabels() {
  labelRAF = null;
  syncLabels();
  if (backend && backend.isMoving()) {
    labelRAF = requestAnimationFrame(positionLabels);
  }
}

function pumpLabels() {
  if (labelRAF == null && backend) labelRAF = requestAnimationFrame(positionLabels);
}

// ── Tooltip ────────────────────────────────────────────────────────────────────
const tooltipEl = document.getElementById("tooltip");
const statusEl  = document.getElementById("status");
let lastPointer = [0, 0];   // latest cursor position, for backends that omit the event
window.addEventListener("mousemove", (e) => { lastPointer = [e.clientX, e.clientY]; });

function showTooltip(node, x, y) {
  if (!node) { tooltipEl.style.display = "none"; return; }
  const label = node.alias && node.alias.trim() ? node.alias : node.id;
  tooltipEl.innerHTML =
    `<div class="tip-id">${escHtml(node.id)}</div>` +
    (label !== node.id ? `<div class="tip-alias">${escHtml(label)}</div>` : "") +
    `<div class="tip-status">${escHtml(node.type || "")}` +
    (node.status ? ` · ${escHtml(node.status)}` : "") +
    (node.ghost ? ` · <em>dangling</em>` : "") +
    `</div>`;
  const pad = 12;
  const tw = 270, th = 80;
  let tx = x + pad, ty = y - th / 2;
  if (tx + tw > window.innerWidth)  tx = x - tw - pad;
  if (ty < pad)                     ty = pad;
  if (ty + th > window.innerHeight) ty = window.innerHeight - th - pad;
  tooltipEl.style.left    = `${tx}px`;
  tooltipEl.style.top     = `${ty}px`;
  tooltipEl.style.display = "block";
}
function hideTooltip() { tooltipEl.style.display = "none"; }

// Resolve cursor screen coordinates: prefer a real MouseEvent, then a cosmos
// screen-space [x,y] array, else the last tracked pointer.
function cursorXY(pos, ev) {
  if (ev && Number.isFinite(ev.clientX) && Number.isFinite(ev.clientY)) return [ev.clientX, ev.clientY];
  if (Array.isArray(pos) && Number.isFinite(pos[0]) && Number.isFinite(pos[1])) return [pos[0], pos[1]];
  return lastPointer;
}

function escHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// Shared hover handler — both backends funnel node-over here with whatever
// position info they carry.
function handleNodeMouseOver(n, pos, ev) {
  if (!n) return;
  const nd = nodeIndex[n.id] || n;
  const [x, y] = cursorXY(pos, ev);
  showTooltip(nd, x, y);
}

// ── State ──────────────────────────────────────────────────────────────────────
let backend   = null;   // active render-backend adapter
let nodeIndex = {};     // id → node, for tooltip lookup

// ── Backend adapter: cosmos.gl (WebGL) ──────────────────────────────────────────
function rgba255(c) { return [c[0] * 255, c[1] * 255, c[2] * 255, c[3]]; }

function makeCosmosBackend(Graph) {
  let g = null;
  let curNodes = [], curLinks = [];
  return {
    init(rootEl, opts) {
      const canvas = rootEl.querySelector("canvas") || rootEl;
      g = new Graph(canvas, {
        backgroundColor:  "#0d1117",
        spaceSize:        4096,
        nodeColor:        n => rgba255(opts.nodeRGBA(n)),
        nodeSize:         n => opts.nodeSize(n),
        nodeSizeScale:    1,
        scaleNodesOnZoom: false,
        linkColor:        l => rgba255(opts.linkRGBA(l)),
        linkWidth:        opts.linkWidth,
        curvedLinks:      false,
        fitViewOnInit:    true,
        simulation: {
          repulsion:      opts.sim.repulsion,
          repulsionTheta: 1.7,
          linkSpring:     opts.sim.linkSpring,
          linkDistance:   opts.sim.linkDistance,
          gravity:        opts.sim.gravity,
          decay:          opts.sim.decay,
          friction:       opts.sim.friction,
          onStart:        () => opts.onEngStart(),
          onEnd:          () => opts.onEngEnd(),
        },
        events: {
          onNodeMouseOver: (n, i, pos, ev) => opts.onHover(n, pos, ev),
          onNodeMouseOut:  () => opts.onOut(),
          onClick:         (node) => opts.onClick(node && node.id != null ? node : null),
          onZoom:          () => opts.onCamNudge(),   // fires per transform → one label sync each
          onZoomEnd:       () => opts.onCamNudge(),   // final settle sync
        },
      });
    },
    setData(nodes, links) {
      curNodes = nodes; curLinks = links;
      g.setData(nodes, links);
    },
    refresh() { if (g) g.setData(curNodes, curLinks, false); },
    forEachScreenPos(cb) {
      if (!g) return;
      let positions;
      try { positions = g.getNodePositionsMap(); } catch (e) { return; }
      if (!positions) return;
      const entries = positions instanceof Map ? positions : Object.entries(positions);
      for (const [id, pos] of entries) {
        if (!pos) continue;
        let screen;
        try { screen = g.spaceToScreenPosition([pos[0], pos[1]]); } catch (e) { continue; }
        if (screen) cb(id, screen[0], screen[1]);
      }
    },
    isMoving() { return !!(g && g.isSimulationRunning); },
  };
}

// ── Backend adapter: force-graph (2D canvas) ────────────────────────────────────
function cssRGBA(c) {
  return `rgba(${Math.round(c[0] * 255)}, ${Math.round(c[1] * 255)}, ${Math.round(c[2] * 255)}, ${c[3]})`;
}

function makeForceGraphBackend(ForceGraph) {
  let fg = null;
  let engineRunning = false;
  let curNodes = [];
  let idleTimer = null;
  let needsFit = false;   // frame the whole graph once after the first layout settles

  // Park the render loop once the layout has cooled AND the user has gone idle;
  // any pointer/wheel activity resumes it. This is what keeps the 2D canvas from
  // repainting a static scene 60fps forever.
  function schedulePark() {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      if (!engineRunning) fg.pauseAnimation();
    }, 400);
  }
  function wake() {
    if (!fg) return;
    fg.resumeAnimation();
    schedulePark();
  }

  return {
    init(rootEl, opts) {
      fg = ForceGraph()(rootEl)
        .backgroundColor("#0d1117")
        .nodeRelSize(1)
        .nodeVal(n => { const r = opts.nodeSize(n); return r * r; })  // radius = sqrt(val)*relSize
        .nodeColor(n => cssRGBA(opts.nodeRGBA(n)))
        .linkColor(l => cssRGBA(opts.linkRGBA(l)))
        .linkWidth(opts.linkWidth)
        .warmupTicks(0)
        .cooldownTicks(200)
        .onNodeHover(node => { if (node) opts.onHover(node, null, null); else opts.onOut(); })
        .onNodeClick(node => opts.onClick(node || null))
        .onBackgroundClick(() => opts.onClick(null))
        .onZoom(() => { wake(); opts.onCamNudge(); })     // per transform: keep drawing + sync labels
        .onZoomEnd(() => opts.onCamNudge())
        .onEngineStop(() => {
          engineRunning = false;
          if (needsFit) { needsFit = false; fg.zoomToFit(400, 40); }  // frame graph on first settle (cosmos fitViewOnInit parity)
          opts.onEngEnd();
          schedulePark();
        });

      // Map cosmos-scale sim params onto d3-force. repulsion → charge strength,
      // linkDistance → link distance, gravity → center pull. Values are tuned so
      // clusters spread into a legible 2D map rather than a central blob.
      const charge = fg.d3Force("charge");
      if (charge) charge.strength(-opts.sim.repulsion * 120).theta(0.9);
      const link = fg.d3Force("link");
      if (link) link.distance(opts.sim.linkDistance * 3);
      fg.d3VelocityDecay(1 - opts.sim.friction);

      // Resume the render loop on any interaction; re-park after a short idle.
      for (const ev of ["pointerdown", "pointermove", "wheel"]) {
        rootEl.addEventListener(ev, wake, { passive: true });
      }
    },
    setData(nodes, links) {
      if (curNodes.length === 0) needsFit = true;   // first load only: fit once, like cosmos fitViewOnInit
      curNodes = nodes;
      // force-graph mutates node objects (adds x/y/vx/vy); pushing new data reheats.
      fg.graphData({ nodes, links });
      engineRunning = true;
      wake();
    },
    refresh() {
      if (!fg) return;
      // Re-register the accessors so force-graph repaints without reheating layout.
      fg.nodeColor(fg.nodeColor()).nodeVal(fg.nodeVal()).linkColor(fg.linkColor());
      wake();
    },
    forEachScreenPos(cb) {
      if (!fg) return;
      for (const n of curNodes) {
        if (n.x == null || n.y == null) continue;
        const p = fg.graph2ScreenCoords(n.x, n.y);
        if (p) cb(n.id, p.x, p.y);
      }
    },
    isMoving() { return engineRunning; },
  };
}

// ── Render data ──────────────────────────────────────────────────────────────────
function renderData(data) {
  if (!data || !Array.isArray(data.nodes)) return;
  const nodes = data.nodes;
  const links = data.links || [];

  nodeIndex = {};
  for (const n of nodes) nodeIndex[n.id] = n;

  allNodes = nodes;
  allLinks = links;
  for (const n of nodes) {
    if (!knownTypes.has(n.type)) { knownTypes.add(n.type); activeTypes.add(n.type); }
  }
  // Re-resolve the STORED highlight against the fresh graph — survives
  // rebuild if the node's still there, clears if it's gone (sp011 AC).
  // Task 4: the cursor-driven isolate is re-derived from that highlight
  // (manual click isolate has no stored source, so it still clears).
  recomputeHighlight();
  selectedKeep = highlightId != null ? neighborsOf(highlightId) : null;

  backend.setData(nodes, links);
  buildLabels(nodes);
  buildLegend(nodes);
  applyLabelVisibility();
  applyIsolate(selectedKeep); // labels rebuilt from scratch; reapply dim state
  applyHighlightLabel();      // ...and emphasis
  pumpLabels();

  document.title = `OK nodes=${nodes.length}`;
  statusEl.textContent = `nodes: ${nodes.length}  links: ${links.length}`;
}

// ── Fetch initial graph ────────────────────────────────────────────────────────
async function fetchGraph() {
  const params = new URLSearchParams(window.location.search);
  const fixture = params.get("fixture");
  const url = fixture ? `./${fixture}` : "/api/graph";
  try {
    const resp = await fetch(url);
    if (!resp.ok) throw new Error(`HTTP ${resp.status}`);
    const data = await resp.json();
    renderData(data);
  } catch (err) {
    console.warn("akm-graph: fetch failed:", err.message);
    statusEl.textContent = "fetch failed — ws will apply data if daemon starts";
  }
}

// ── WebSocket with exponential backoff ────────────────────────────────────────
let wsDelay = 1000;
const WS_MAX = 30000;
let wsTimer = null;

// handleHighlightMessage applies (or ignores) an inbound {type:"highlight",
// id, slot} message. Slot-scoped: a standalone viewer (no ?slot= on the URL,
// openSlot === null) ignores every highlight message — it has no "own slot"
// to match — and an embedded viewer ignores any message whose slot isn't its
// own (sp011 edge cases: standalone ignores slot-tagged, wrong-slot ignored).
function handleHighlightMessage(msg) {
  if (openSlot == null) return;        // standalone viewer: no slot to match
  if (msg.slot !== openSlot) return;   // not our slot
  setHighlight(msg.id || null);
}

// handleWSMessage is the single shape-discrimination point for every /watch
// frame: a {"type":"highlight",...} envelope routes to the highlight path,
// anything else is treated as a raw {nodes,links} graph payload — the
// existing reload path, unchanged (sp011 anti-pattern guard: never wrap the
// graph payload in a typed envelope, so this must stay a shape check, not a
// type-tag check on the graph side). Factored out of ws.onmessage so smoke
// tests can drive it directly with canned messages, no real WebSocket needed.
function handleWSMessage(raw) {
  let msg;
  try { msg = JSON.parse(raw); }
  catch (e) { console.warn("akm-graph: invalid ws payload"); return; }
  if (msg && msg.type === "highlight") { handleHighlightMessage(msg); return; }
  renderData(msg);
}

function connectWS() {
  if (wsTimer) { clearTimeout(wsTimer); wsTimer = null; }
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const url = `${proto}://${location.host}/watch`;
  let ws;
  try { ws = new WebSocket(url); } catch (e) { scheduleReconnect(); return; }
  ws.onopen = () => { wsDelay = 1000; };
  ws.onmessage = (evt) => handleWSMessage(evt.data);
  ws.onclose = () => { scheduleReconnect(); };
  ws.onerror = () => {};   // always followed by onclose; don't log to avoid spam
}

function scheduleReconnect() {
  if (wsTimer) return;
  wsTimer = setTimeout(() => { wsTimer = null; connectWS(); }, wsDelay);
  wsDelay = Math.min(wsDelay * 2, WS_MAX);
}

// ── Backend selection + bootstrap ───────────────────────────────────────────────
function resolveBackendName() {
  const q = new URLSearchParams(location.search).get("backend");
  if (q === "cosmos" || q === "force-graph") return q;
  const meta = document.querySelector('meta[name="akm-backend"]');
  const m = meta && meta.getAttribute("content");
  if (m === "cosmos" || m === "force-graph") return m;
  return "force-graph";
}

function loadScript(src) {
  return new Promise((res, rej) => {
    const s = document.createElement("script");
    s.src = src; s.onload = res; s.onerror = () => rej(new Error(`load ${src}`));
    document.head.appendChild(s);
  });
}

async function makeBackend(name) {
  if (name === "cosmos") {
    const mod = await import("./cosmos-bundle.js");
    return makeCosmosBackend(mod.Graph);
  }
  await loadScript("./force-graph-bundle.js");
  return makeForceGraphBackend(window.ForceGraph);
}

// The accessor + event bundle every adapter is initialised with.
const backendOpts = {
  nodeRGBA, linkRGBA, nodeSize, linkWidth: 1.1,
  sim: { repulsion: 1.3, linkSpring: 1.2, linkDistance: 10, gravity: 0.25, decay: 3000, friction: 0.85 },
  onHover: handleNodeMouseOver,
  onOut:   hideTooltip,
  onClick: (node) => { if (node && node.id != null) selectNode(node.id); else clearSelection(); },
  onCamNudge: () => pumpLabels(),   // one label sync per camera transform event
  onEngStart: () => pumpLabels(),
  onEngEnd:   () => pumpLabels(),
};

async function boot() {
  const name = resolveBackendName();
  const rootEl = document.getElementById("graph-root");
  try {
    backend = await makeBackend(name);
  } catch (e) {
    console.error("akm-graph: backend load failed:", name, e);
    statusEl.textContent = `backend load failed: ${name}`;
    return;
  }
  backend.init(rootEl, backendOpts);
  statusEl.dataset.backend = name;
  fetchGraph();
  connectWS();
  window.addEventListener("resize", () => pumpLabels());
}

boot();

// Test hook — lets the headless smoke test drive handlers without real events.
window.__akmGraph = {
  onNodeMouseOver: (n, i, pos, ev) => handleNodeMouseOver(n, pos, ev),
  onNodeMouseOut: hideTooltip,
  nodeById: (id) => nodeIndex[id],
  tooltipState: () => ({
    display: tooltipEl.style.display,
    left: tooltipEl.style.left,
    top: tooltipEl.style.top,
    text: tooltipEl.textContent,
  }),
  selectNode,
  clearSelection,
  dimState: () => {
    const total = Object.keys(labelEls).length;
    const dim = Object.values(labelEls).filter((el) => el.classList.contains("dim")).length;
    return { total, dim, lit: total - dim };
  },
  // sp011 Task 4: expose the isolate set so smoke-highlight.html can assert
  // the cursor-driven neighborhood (null = no isolate active).
  keepIds: () => (selectedKeep ? Array.from(selectedKeep) : null),
  toggleType,
  filterState: () => {
    const total = Object.keys(labelEls).length;
    const hidden = Object.values(labelEls).filter((el) => el.classList.contains("hidden")).length;
    return {
      active: [...activeTypes].sort(),
      chips: legendEl.querySelectorAll(".legend-chip").length,
      total,
      hidden,
      shown: total - hidden,
    };
  },
  backendName: () => (statusEl.dataset.backend || null),
  // simulateWS feeds a canned message through the exact same shape-discrimination
  // + apply/render path a real /watch frame would (sp011 ft004 Task 2 smoke
  // hook) — pass a graph payload {nodes,links} to drive the reload path, or
  // {type:"highlight", id, slot} to drive the highlight path.
  simulateWS: (obj) => handleWSMessage(JSON.stringify(obj)),
  highlightState: () => {
    const lit = Object.entries(labelEls).find(([, el]) => el.classList.contains("highlight"));
    return {
      stored: storedHighlightId,
      active: highlightId,
      ownSlot: openSlot,
      labelHighlighted: lit ? lit[0] : null,
    };
  },
};
