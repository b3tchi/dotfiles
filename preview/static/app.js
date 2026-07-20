// preview shell client (sp008 Task 4). Opens a websocket back to this same
// /preview<N> slot and hot-swaps the shown file as redraw messages arrive —
// no full page reload (ft005 api_surface /preview<N>).
(() => {
  "use strict";

  // ── sp008 Task 10: akm/d2 reverse-channel postMessage listener ─────────
  //
  // ASSUMED CONTRACT — sp009/sp010 (the ft004 akm-graph / ft002 d2-router
  // page-side EMIT) are both still `status: idea`, NOT shipped anywhere.
  // This is deliberately the LISTENER half only, built against an assumed
  // message shape so it can be implemented and tested now; reconcile against
  // whatever sp009/sp010 actually ship.
  //
  //   event.data   = { type: "preview-open", path: "<root-relative-or-
  //                    absolute file path>" }
  //   event.origin must be one of the known embedded-iframe origins:
  //     - akm-graph (ft004):    http://localhost:4810
  //     - d2-router (ft002):    http://localhost:4800
  //     - this shell's own origin — the /d2embed/ same-origin proxy route
  //       (proxy.go handleD2Embed) serves d2-router's page through preview-d
  //       itself, so that message would arrive with location.origin, not
  //       d2-router's origin.
  //   Any other origin is rejected silently (edge case: postMessage from an
  //   unexpected origin -> ignored, not an error).
  //
  //   The emitting page is expected to post to window.top (or otherwise
  //   ensure delivery reaches this top-level shell document directly) since
  //   akm-graph/d2-router render inside a NESTED iframe one level below this
  //   shell (renderAkmEmbed/renderD2Embed in proxy.go wrap them in an
  //   intermediate /file/<path> document) — a plain window.parent.postMessage
  //   from that nested iframe would only reach the intermediate document,
  //   not this shell. That's on the sp009/sp010 emit side to get right.
  //
  // Registered synchronously as the very first thing this script does (before
  // any other setup, including the websocket connect below) so no message
  // sent after the shell finishes loading can be missed: postMessage delivery
  // is always an asynchronous task, so any listener already attached by the
  // time this synchronous script finishes executing is guaranteed to see it —
  // no separate buffering scheme is needed.
  //
  // A node/element with no backing file is expected to omit `path` (or send
  // an empty string) rather than error — treated as a silent no-op here too.
  const PREVIEW_OPEN_ORIGINS = [
    "http://localhost:4810", // akm-graph (ft004)
    "http://localhost:4800", // d2-router (ft002)
    location.origin, // same-origin /d2embed/ proxy (proxy.go handleD2Embed)
  ];

  function isAllowedPreviewOrigin(origin) {
    return PREVIEW_OPEN_ORIGINS.indexOf(origin) !== -1;
  }

  function extractOpenPath(data) {
    if (!data || typeof data !== "object") return "";
    if (data.type !== "preview-open") return "";
    return typeof data.path === "string" ? data.path : "";
  }

  function handlePreviewOpenMessage(event) {
    if (!isAllowedPreviewOrigin(event.origin)) return; // wrong origin -> ignore
    const path = extractOpenPath(event.data);
    if (!path) return; // no backing file / malformed -> no-op, no error
    fetch("/open", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path }),
    }).catch(() => {}); // best-effort; failures surface via nvim, not here
  }

  addEventListener("message", handlePreviewOpenMessage);

  const contentEl = document.getElementById("content");
  const emptyEl = document.getElementById("empty");

  // ── sp009 Task 6: slot threading ────────────────────────────────────────
  //
  // This shell is served at /preview<N> — parse N once from the shell's own
  // URL path so every /file/<path> load into the content iframe can carry
  // it through (?slot=N), which handleFile/renderAkmEmbed (proxy.go) then
  // thread onto the embedded akm-graph iframe's own src. That's what lets a
  // click inside the embedded graph route back through /open to THIS
  // window's slot rather than some other window's. A pathname that doesn't
  // match /preview<N> (shouldn't happen — the shell is always served at
  // that path) leaves SLOT null, and encodeFilePath below omits the query
  // param entirely — the same back-compat shape as no slot at all.
  const SLOT = (() => {
    const m = location.pathname.match(/^\/preview(\d+)$/);
    return m ? m[1] : null;
  })();

  // encodeFilePath turns a root-relative path into a /file/<path> URL,
  // percent-encoding each segment individually so a literal "/" in the
  // path stays a directory separator rather than becoming %2F. Appends
  // ?slot=<this window's N> when known (sp009 Task 6) so the embedded akm
  // graph inherits which /preview<N> slot it's rendering inside of.
  function encodeFilePath(path) {
    const base = "/file/" + path.split("/").map(encodeURIComponent).join("/");
    return SLOT !== null ? base + "?slot=" + SLOT : base;
  }

  // Image previews get a fit-to-window wrapper instead of navigating the
  // iframe straight at the raw image bytes. WebKit renders a bare image
  // document at native size (top-left), so a 2560px screenshot overflowed
  // and a small image sat tiny in the corner — neither zoomed to the window
  // (dotfiles-ad7 follow-up). Wrapping full-res (?full, not the 320px
  // thumbnail — the fitted image stays crisp) in an <img object-fit:contain>
  // that fills the viewport scales every image to fit, up or down. The
  // extension list mirrors renderImage's server-side isImageExt so only
  // paths the daemon actually serves as raw image bytes take this branch.
  const IMAGE_EXTS = ["png", "jpg", "jpeg", "gif"];
  function isImagePath(path) {
    const dot = path.lastIndexOf(".");
    return dot >= 0 && IMAGE_EXTS.includes(path.slice(dot + 1).toLowerCase());
  }

  // imageDoc builds a self-contained document (loaded via the iframe's
  // srcdoc) that fits the image to the window by default and toggles to 1:1
  // actual-pixel view — scrollable when the image is larger than the window
  // — on click or the z / 1 / space key. The toggle logic lives inside this
  // document's own <script> rather than the parent shell because the image
  // renders inside the iframe; the parent has no handle on the img element.
  function imageDoc(path) {
    const url = "/file/" + path.split("/").map(encodeURIComponent).join("/") + "?full";
    return "<!doctype html><meta charset=utf-8>" +
      "<style>" +
      "html,body{margin:0;height:100vh;background:#111;overflow:hidden}" +
      "body.actual{overflow:auto}" +
      "img{display:block;width:100vw;height:100vh;object-fit:contain;cursor:zoom-in}" +
      "body.actual img{width:auto;height:auto;object-fit:none;margin:auto;cursor:zoom-out}" +
      "</style>" +
      '<img src="' + url + '" alt="">' +
      "<script>" +
      "var b=document.body,f=function(e){b.classList.toggle('actual');" +
      "if(e&&e.preventDefault)e.preventDefault();};" +
      "document.querySelector('img').addEventListener('click',f);" +
      "addEventListener('keydown',function(e){" +
      "if(e.key==='z'||e.key==='1'||e.key===' ')f(e);});" +
      "addEventListener('load',function(){window.focus();});" +
      "</script>";
  }

  // showFile hot-swaps the iframe to the given root-relative path without a
  // page reload. An empty path reverts to the "waiting for a file" state.
  // Images load via srcdoc (imageDoc above); everything else navigates the
  // iframe at /file/<path>. Whichever attribute isn't in use is cleared so a
  // lingering srcdoc (which takes precedence over src) can't mask a later
  // non-image load, and vice-versa.
  function showFile(path) {
    if (!path) {
      contentEl.style.display = "none";
      emptyEl.style.display = "flex";
      return;
    }
    if (isImagePath(path)) {
      contentEl.removeAttribute("src");
      contentEl.srcdoc = imageDoc(path);
    } else {
      contentEl.removeAttribute("srcdoc");
      contentEl.src = encodeFilePath(path);
    }
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
