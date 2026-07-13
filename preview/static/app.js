// preview shell client (sp008 Task 4). Opens a websocket back to this same
// /preview<N> slot and hot-swaps the shown file as redraw messages arrive —
// no full page reload (ft005 api_surface /preview<N>).
(() => {
  "use strict";

  const contentEl = document.getElementById("content");
  const emptyEl = document.getElementById("empty");

  // encodeFilePath turns a root-relative path into a /file/<path> URL,
  // percent-encoding each segment individually so a literal "/" in the
  // path stays a directory separator rather than becoming %2F.
  function encodeFilePath(path) {
    return "/file/" + path.split("/").map(encodeURIComponent).join("/");
  }

  // showFile hot-swaps the iframe to the given root-relative path without a
  // page reload. An empty path reverts to the "waiting for a file" state.
  function showFile(path) {
    if (!path) {
      contentEl.style.display = "none";
      emptyEl.style.display = "flex";
      return;
    }
    contentEl.src = encodeFilePath(path);
    contentEl.style.display = "block";
    emptyEl.style.display = "none";
  }

  // ── WebSocket with exponential backoff (akm-graph static/app.js pattern)
  let wsDelay = 1000;
  const WS_MAX = 30000;
  let wsTimer = null;

  function connectWS() {
    if (wsTimer) { clearTimeout(wsTimer); wsTimer = null; }
    const proto = location.protocol === "https:" ? "wss" : "ws";
    // This shell is served at /preview<N>; opening the websocket at the
    // same path is what lets the daemon resolve which slot this window
    // belongs to (preview/server.go's previewRouter parses <N> from the
    // path for both the HTML GET and the ws upgrade).
    const url = `${proto}://${location.host}${location.pathname}`;
    let ws;
    try { ws = new WebSocket(url); } catch (e) { scheduleReconnect(); return; }
    ws.onopen = () => { wsDelay = 1000; };
    ws.onmessage = (evt) => {
      try {
        const msg = JSON.parse(evt.data);
        showFile(msg.path);
      } catch (e) {
        console.warn("preview: invalid ws payload");
      }
    };
    ws.onclose = () => { scheduleReconnect(); };
    ws.onerror = () => {}; // always followed by onclose; don't log to avoid spam
  }

  function scheduleReconnect() {
    if (wsTimer) return;
    wsTimer = setTimeout(() => { wsTimer = null; connectWS(); }, wsDelay);
    wsDelay = Math.min(wsDelay * 2, WS_MAX);
  }

  connectWS();
})();
