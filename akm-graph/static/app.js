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

// cosmos v1 normalizes array colors as [r/255, g/255, b/255, a] — it expects
// RGB in the 0–255 range, alpha in 0–1. The palette above is authored in 0–1
// for readability, so scale RGB to 0–255 on the way out (alpha untouched).
// Without this every color collapses to ~black and links vanish on the dark bg.
function rgba255(c) {
  return [c[0] * 255, c[1] * 255, c[2] * 255, c[3]];
}
const LINK_COLOR = rgba255([0.25, 0.30, 0.35, 0.6]);

// ── Size by degree ─────────────────────────────────────────────────────────────
// Nodes are sized by degree but floored at MIN_SIZE so even a 0-degree node is
// clearly visible (the country-borders demo look: every node a legible dot,
// hubs noticeably larger).
const MIN_SIZE  = 6;
const BASE_SIZE = 6;
const MAX_SIZE  = 34;
const SIZE_K    = 1.6;   // pixels per degree

function nodeSize(n) {
  const s = Math.min(BASE_SIZE + (n.degree || 0) * SIZE_K, MAX_SIZE);
  if (n.ghost) return Math.max(s * 0.6, 4);
  return Math.max(s, MIN_SIZE);
}

function nodeColor(n) {
  if (n.ghost) return rgba255(GHOST_COLOR);
  return rgba255(TYPE_COLORS[n.type] || DEFAULT_COLOR);
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
    scaleNodesOnZoom: true,           // nodes grow as you zoom in — stay legible
    renderHoveredNodeRing: true,      // highlight the hovered node
    linkColor:        LINK_COLOR,
    linkWidth:        1.1,
    curvedLinks:      true,           // gentle arcs — the country-borders look
    fitViewOnInit:    true,           // frame the whole graph on load
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

  graph.setData(nodes, links);

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
};
