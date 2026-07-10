// akm-graph viewer — app.js
// Cosmos v1 API: new Graph(canvas, config), graph.setData(nodes, links)
// Graph JSON: {nodes:[{id,type,status,alias,degree,ghost}], links:[{source,target}]}

import { Graph } from "./cosmos-bundle.js";

// ── Color palette — one distinct color per node type ──────────────────────────
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

// Human-readable legend names + display order for the category toggle panel.
// Any type not listed still gets a chip (falls back to the raw type code).
const TYPE_LABELS = {
  us: "stories", sp: "specs", im: "impl", ft: "features", adr: "decisions",
  cat: "categories", poc: "pocs", pn: "personal", hub: "hubs", note: "notes",
};
const TYPE_ORDER = ["us", "sp", "im", "ft", "adr", "cat", "poc", "pn", "hub", "note"];

// cosmos v1 normalizes array colors as [r/255, g/255, b/255, a] — it expects
// RGB in the 0–255 range, alpha in 0–1. The palette above is authored in 0–1
// for readability, so scale RGB to 0–255 on the way out (alpha untouched).
// Without this every color collapses to ~black and links vanish on the dark bg.
function rgba255(c) {
  return [c[0] * 255, c[1] * 255, c[2] * 255, c[3]];
}
const LINK_COLOR  = rgba255([0.25, 0.30, 0.35, 0.6]);
const LINK_HIDDEN = [0, 0, 0, 0];   // link with a toggled-off endpoint disappears

// ── Category toggle state ────────────────────────────────────────────────────
// activeTypes holds the node types currently shown. Toggling a legend chip
// adds/removes a type here, then a setData(...,false) recompute hides the nodes
// and their links WITHOUT restarting the simulation (layout stays put).
const activeTypes = new Set();  // types currently visible
const knownTypes  = new Set();  // every type ever seen (so refreshes keep state)

function typeVisible(t) { return activeTypes.has(t); }
function nodeShown(n)   { return n && activeTypes.has(n.type); }

// Resolve a link endpoint (id string OR node object) to its node record.
function endpointNode(e) {
  if (e == null) return null;
  const id = (typeof e === "object" && e.id != null) ? e.id : e;
  return nodeIndex[id] || (typeof e === "object" ? e : null);
}

// ── Size by degree ─────────────────────────────────────────────────────────────
// Nodes are sized by degree but floored at MIN_SIZE so even a 0-degree node is
// clearly visible (the country-borders demo look: every node a legible dot,
// hubs noticeably larger).
const MIN_SIZE  = 3;
const BASE_SIZE = 3;
const MAX_SIZE  = 10;
const SIZE_K    = 0.8;   // pixels per degree

function nodeSize(n) {
  if (!nodeShown(n)) return 0;   // toggled-off type: zero radius = gone + unhoverable
  const s = Math.min(BASE_SIZE + (n.degree || 0) * SIZE_K, MAX_SIZE);
  if (n.ghost) return Math.max(s * 0.7, 2);
  return Math.max(s, MIN_SIZE);
}

function nodeColor(n) {
  if (!nodeShown(n)) return rgba255(HIDDEN_COLOR);
  if (n.ghost) return rgba255(GHOST_COLOR);
  return rgba255(TYPE_COLORS[n.type] || DEFAULT_COLOR);
}

// Link color accessor: a link vanishes if either endpoint's type is toggled off.
function linkColor(l) {
  const s = endpointNode(l && l.source);
  const t = endpointNode(l && l.target);
  if ((s && !nodeShown(s)) || (t && !nodeShown(t))) return LINK_HIDDEN;
  return LINK_COLOR;
}

// CSS rgb() string for a node's type — used to tint its persistent label pill.
function cssColor(n) {
  const c = n.ghost ? GHOST_COLOR : (TYPE_COLORS[n.type] || DEFAULT_COLOR);
  return `rgb(${Math.round(c[0] * 255)}, ${Math.round(c[1] * 255)}, ${Math.round(c[2] * 255)})`;
}

// ── Persistent node labels (HTML overlay) ───────────────────────────────────────
// cosmos core has no text labels, so we render one HTML pill per node and sync
// it to the node's screen position every animation frame (country-borders look).
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
// cosmos greys out non-selected nodes/links (nodeGreyoutOpacity/linkGreyoutOpacity);
// we mirror that on the HTML labels via a .dim class.
function selectNode(id) {
  if (!graph) return;
  graph.selectNodeById(id, true);   // node + adjacent selected, rest greyed
  const keep = new Set([id]);
  let adj;
  try { adj = graph.getAdjacentNodes(id); } catch (e) { adj = null; }
  if (adj) for (const a of adj) keep.add(a.id);
  for (const [nid, el] of Object.entries(labelEls)) {
    el.classList.toggle("dim", !keep.has(nid));
  }
}

function clearSelection() {
  if (graph) graph.unselectNodes();
  for (const el of Object.values(labelEls)) el.classList.remove("dim");
}

// ── Category legend (type toggle) ───────────────────────────────────────────────
// One chip per node type present. Clicking a chip flips that type's membership
// in activeTypes, then re-pushes the same data with runSimulation=false so the
// GPU buffers (color/size) recompute against the new state but positions freeze.
const legendEl = document.getElementById("legend");
let allNodes = [];
let allLinks = [];

function typesPresent(nodes) {
  const counts = {};
  for (const n of nodes) counts[n.type] = (counts[n.type] || 0) + 1;
  const seen = Object.keys(counts);
  // known order first, then any stragglers alphabetically
  const ordered = TYPE_ORDER.filter(t => t in counts)
    .concat(seen.filter(t => !TYPE_ORDER.includes(t)).sort());
  return ordered.map(t => ({ type: t, count: counts[t] }));
}

function buildLegend(nodes) {
  legendEl.textContent = "";
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
  // recompute node/link buffers without restarting the layout
  if (graph) graph.setData(allNodes, allLinks, false);
  applyLabelVisibility();
  const chip = legendEl.querySelector(`.legend-chip[data-type="${type}"]`);
  if (chip) chip.classList.toggle("off", !typeVisible(type));
}

// positionLabels runs on every frame: project each node's graph-space position
// to screen coordinates and park its pill just above the dot.
function positionLabels() {
  labelRAF = requestAnimationFrame(positionLabels);
  if (!graph) return;
  let positions;
  try { positions = graph.getNodePositionsMap(); } catch (e) { return; }
  if (!positions) return;
  const entries = positions instanceof Map ? positions : Object.entries(positions);
  for (const [id, pos] of entries) {
    const el = labelEls[id];
    if (!el || !pos) continue;
    let screen;
    try { screen = graph.spaceToScreenPosition([pos[0], pos[1]]); } catch (e) { continue; }
    if (!screen) continue;
    el.style.transform =
      `translate(${Math.round(screen[0])}px, ${Math.round(screen[1])}px) translate(-50%, -190%)`;
  }
}

function startLabelLoop() {
  if (labelRAF == null) positionLabels();
}

// ── State ──────────────────────────────────────────────────────────────────────
let graph = null;       // cosmos Graph instance
let nodeIndex = {};     // id → node, for tooltip lookup

// ── Tooltip ────────────────────────────────────────────────────────────────────
const tooltipEl = document.getElementById("tooltip");
const statusEl  = document.getElementById("status");

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
  // keep tooltip within viewport
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

// Resolve cursor screen coordinates from cosmos' hover callback args.
// Prefer the real MouseEvent (ev.clientX/clientY); fall back to the
// screen-space `position` [x, y] array cosmos passes as the 3rd arg.
function cursorXY(pos, ev) {
  if (ev && Number.isFinite(ev.clientX) && Number.isFinite(ev.clientY)) {
    return [ev.clientX, ev.clientY];
  }
  if (Array.isArray(pos) && Number.isFinite(pos[0]) && Number.isFinite(pos[1])) {
    return [pos[0], pos[1]];
  }
  return [0, 0];
}

function escHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

// ── Hover handler (cosmos v1 four-arg callback) ─────────────────────────────────
// Exposed via window.__akmGraph for the smoke test so it can drive the exact
// callback cosmos invokes — (node, index, position, currentEvent) — without a
// real WebGL pointer event.
function handleNodeMouseOver(n, i, pos, ev) {
  if (!n) return;
  const nd = nodeIndex[n.id] || n;
  const [x, y] = cursorXY(pos, ev);
  showTooltip(nd, x, y);
}

// ── Init cosmos ────────────────────────────────────────────────────────────────
function initGraph() {
  const canvas = document.getElementById("canvas");
  graph = new Graph(canvas, {
    backgroundColor:  "#0d1117",
    spaceSize:        4096,
    nodeColor:        n => nodeColor(n),
    nodeSize:         n => nodeSize(n),
    nodeSizeScale:    1,
    scaleNodesOnZoom: false,          // fixed screen-size dots — crisp, no ballooning at fit-zoom
    linkColor:        l => linkColor(l),
    linkWidth:        1.1,
    curvedLinks:      false,          // straight, direct edges between nodes
    fitViewOnInit:    true,           // frame the whole graph on load
    nodeGreyoutOpacity: 0.1,          // dim non-selected nodes on click-isolate
    linkGreyoutOpacity: 0.1,
    // Force-directed spread: stronger repulsion + light gravity pushes clusters
    // apart into a legible 2D map instead of a tight central blob. decay left at
    // the cosmos default (1000) so the layout settles instead of jittering
    // forever (the old 100000 never cooled).
    simulation: {
      repulsion:      1.3,
      repulsionTheta: 1.7,
      linkSpring:     1.2,
      linkDistance:   10,
      gravity:        0.25,
      decay:          3000,
      friction:       0.85,
    },
    events: {
      // Cosmos v1 invokes this with FOUR args:
      //   (node, index, position, currentEvent)
      // where `position` is a screen-space [x, y] array and `ev` is the
      // MouseEvent. Bind all four — earlier (n, i, e) silently aliased the
      // position array onto `e`, so e.clientX was undefined → NaN px.
      onNodeMouseOver: handleNodeMouseOver,
      onNodeMouseOut() { hideTooltip(); },
      // Click a node -> isolate it + direct neighbors; click empty space -> reset.
      onClick(node) {
        if (node && node.id != null) selectNode(node.id);
        else clearSelection();
      },
    },
  });
  return graph;
}

// ── Render data ────────────────────────────────────────────────────────────────
function renderData(data) {
  if (!data || !Array.isArray(data.nodes)) return;
  const nodes = data.nodes;
  const links = data.links || [];

  // rebuild index
  nodeIndex = {};
  for (const n of nodes) nodeIndex[n.id] = n;

  // stash full data for the category filter; newly-seen types start visible
  allNodes = nodes;
  allLinks = links;
  for (const n of nodes) {
    if (!knownTypes.has(n.type)) { knownTypes.add(n.type); activeTypes.add(n.type); }
  }

  graph.setData(nodes, links);
  buildLabels(nodes);
  buildLegend(nodes);
  applyLabelVisibility();
  startLabelLoop();

  // update document title with node count for smoke test
  document.title = `OK nodes=${nodes.length}`;
  statusEl.textContent = `nodes: ${nodes.length}  links: ${links.length}`;
}

// ── Fetch initial graph ────────────────────────────────────────────────────────
async function fetchGraph() {
  // Support a ?fixture=path query param (for smoke tests and dev):
  //   ?fixture=graph.json  -> fetches ./graph.json instead of /api/graph
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
let wsDelay   = 1000;
const WS_MAX  = 30000;
let wsTimer   = null;

function connectWS() {
  if (wsTimer) { clearTimeout(wsTimer); wsTimer = null; }
  const proto = location.protocol === "https:" ? "wss" : "ws";
  const url   = `${proto}://${location.host}/watch`;
  let ws;
  try {
    ws = new WebSocket(url);
  } catch (e) {
    scheduleReconnect();
    return;
  }

  ws.onopen = () => {
    wsDelay = 1000;
  };

  ws.onmessage = (evt) => {
    try {
      const data = JSON.parse(evt.data);
      renderData(data);
    } catch (e) {
      console.warn("akm-graph: invalid ws payload");
    }
  };

  ws.onclose = () => {
    scheduleReconnect();
  };

  ws.onerror = () => {
    // onerror is always followed by onclose; don't log to avoid spam
  };
}

function scheduleReconnect() {
  if (wsTimer) return;
  wsTimer = setTimeout(() => {
    wsTimer = null;
    connectWS();
  }, wsDelay);
  wsDelay = Math.min(wsDelay * 2, WS_MAX);
}

// ── Bootstrap ──────────────────────────────────────────────────────────────────
initGraph();
fetchGraph();
connectWS();

// Test hook — lets the headless smoke test drive the real hover handler with a
// synthetic cosmos-shaped 4-arg call and inspect tooltip state.
window.__akmGraph = {
  onNodeMouseOver: handleNodeMouseOver,
  onNodeMouseOut: hideTooltip,
  nodeById: (id) => nodeIndex[id],
  tooltipState: () => ({
    display: tooltipEl.style.display,
    left: tooltipEl.style.left,
    top: tooltipEl.style.top,
    text: tooltipEl.textContent,
  }),
  // Selection hooks for the smoke test (drive isolate without a real click).
  selectNode,
  clearSelection,
  dimState: () => {
    const total = Object.keys(labelEls).length;
    const dim = Object.values(labelEls).filter((el) => el.classList.contains("dim")).length;
    return { total, dim, lit: total - dim };
  },
  // Category-toggle hooks for the smoke test.
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
};
