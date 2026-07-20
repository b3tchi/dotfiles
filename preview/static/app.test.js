// Unit tests for preview/static/app.js's postMessage listener (sp008 Task
// 10). No JS test harness pre-existed in this repo (preview-d is Go-only);
// this uses Node's built-in test runner (`node:test`) since Node is already
// a dependency-free way to exercise a plain <script> file — no jsdom/browser
// needed because the listener logic only touches a handful of globals
// (document, location, WebSocket, addEventListener, fetch), all of which are
// shimmed below before the file is require()'d. Node's CommonJS module wrapper
// resolves bare identifiers like `document`/`location` against the process
// global object exactly like a browser resolves them against `window`, so
// setting `global.document = ...` etc. before require() is sufficient — no
// real DOM implementation required.
//
// Run: node --test preview/static/app.test.js

"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");

function loadAppJs({ origin, fetchImpl, pathname }) {
  const listeners = {};
  let wsInstance = null;

  // Real elements (not a fresh `{style:{}}` per call) so a test can read
  // back `.src` after app.js's showFile() sets it — needed for the sp009
  // Task 6 slot-threading tests below, which assert on contentEl.src.
  // removeAttribute deletes the property so showFile's src/srcdoc clearing
  // (dotfiles-ad7: image branch uses srcdoc, non-image uses src) is testable
  // against this plain-object stub the same way a real iframe would drop the
  // attribute.
  const contentEl = { style: {}, removeAttribute(name) { delete this[name]; } };
  const emptyEl = { style: {} };

  global.document = {
    getElementById: (id) => (id === "content" ? contentEl : emptyEl),
  };
  global.location = {
    protocol: "http:",
    host: "localhost:9999",
    pathname: pathname || "/preview1",
    origin: origin,
  };
  global.WebSocket = function FakeWebSocket(_url) {
    // Never actually connects; the listener/showFile tests drive
    // ws.onmessage directly instead, so capturing `this` is enough — no
    // real socket needed.
    wsInstance = this;
  };
  global.addEventListener = (type, handler) => {
    listeners[type] = handler;
  };
  global.fetch = fetchImpl;

  // Bust the require cache so each test gets a fresh listeners map (the IIFE
  // in app.js runs its addEventListener("message", ...) registration exactly
  // once per require, and we want a clean capture per test rather than
  // reusing a stale closure from a previous test's globals).
  const appJsPath = path.join(__dirname, "app.js");
  delete require.cache[require.resolve(appJsPath)];
  require(appJsPath);

  return { listeners, contentEl, emptyEl, getWs: () => wsInstance };
}

function fetchSpy() {
  const calls = [];
  const fn = (...args) => {
    calls.push(args);
    return Promise.resolve({ ok: true });
  };
  fn.calls = calls;
  return fn;
}

test("valid origin + path posts /open with that path", () => {
  const fetchMock = fetchSpy();
  const { listeners } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchMock,
  });

  listeners.message({
    origin: "http://localhost:4810", // akm-graph (ft004)
    data: { type: "preview-open", path: "notes/foo.md" },
  });

  assert.equal(fetchMock.calls.length, 1);
  const [url, opts] = fetchMock.calls[0];
  assert.equal(url, "/open");
  assert.equal(opts.method, "POST");
  assert.deepEqual(JSON.parse(opts.body), { path: "notes/foo.md" });
});

test("d2-router origin + path posts /open with that path", () => {
  const fetchMock = fetchSpy();
  const { listeners } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchMock,
  });

  listeners.message({
    origin: "http://localhost:4800", // d2-router (ft002)
    data: { type: "preview-open", path: "diagrams/x.d2" },
  });

  assert.equal(fetchMock.calls.length, 1);
});

test("same-origin (d2embed proxy) + path posts /open with that path", () => {
  const fetchMock = fetchSpy();
  const { listeners } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchMock,
  });

  listeners.message({
    origin: "http://localhost:9999", // shell's own origin (/d2embed/ proxy)
    data: { type: "preview-open", path: "diagrams/y.d2" },
  });

  assert.equal(fetchMock.calls.length, 1);
});

test("message from an unexpected origin is ignored", () => {
  const fetchMock = fetchSpy();
  const { listeners } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchMock,
  });

  listeners.message({
    origin: "http://evil.example",
    data: { type: "preview-open", path: "notes/foo.md" },
  });

  assert.equal(fetchMock.calls.length, 0);
});

test("empty path is a no-op", () => {
  const fetchMock = fetchSpy();
  const { listeners } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchMock,
  });

  listeners.message({
    origin: "http://localhost:4810",
    data: { type: "preview-open", path: "" },
  });

  assert.equal(fetchMock.calls.length, 0);
});

test("missing path field is a no-op", () => {
  const fetchMock = fetchSpy();
  const { listeners } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchMock,
  });

  listeners.message({
    origin: "http://localhost:4810",
    data: { type: "preview-open" },
  });

  assert.equal(fetchMock.calls.length, 0);
});

test("unrelated message type is a no-op", () => {
  const fetchMock = fetchSpy();
  const { listeners } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchMock,
  });

  listeners.message({
    origin: "http://localhost:4810",
    data: { type: "something-else", path: "notes/foo.md" },
  });

  assert.equal(fetchMock.calls.length, 0);
});

// ── sp009 Task 6: slot threading — /preview<N> -> handleFile -> renderAkmEmbed
//
// The shell knows its own window N from its own URL path (/preview<N>).
// showFile (driven here via a fake ws.onmessage, the same path a real
// redraw broadcast takes) must encode /file/<path> with ?slot=N appended so
// the daemon can thread it through to the embedded akm-graph iframe.

test("showFile appends this window's slot number to the /file/<path> src", () => {
  const { contentEl, getWs } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchSpy(),
    pathname: "/preview3",
  });

  getWs().onmessage({ data: JSON.stringify({ path: "notes/foo.md" }) });

  assert.equal(contentEl.src, "/file/notes/foo.md?slot=3");
});

test("showFile omits ?slot when the shell's own path doesn't carry a slot number", () => {
  const { contentEl, getWs } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchSpy(),
    pathname: "/not-a-preview-slot",
  });

  getWs().onmessage({ data: JSON.stringify({ path: "notes/foo.md" }) });

  assert.equal(contentEl.src, "/file/notes/foo.md");
});

// ── dotfiles-ad7: image previews fit the window ──────────────────────────
//
// An image path loads via srcdoc (a fit-to-window <img>), not by navigating
// the iframe at the raw bytes, so a large screenshot scales down and a small
// image scales up to the window instead of rendering at native size.

test("showFile wraps an image in a fit-to-window srcdoc pointing at ?full", () => {
  const { contentEl, getWs } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchSpy(),
    pathname: "/preview1",
  });

  getWs().onmessage({ data: JSON.stringify({ path: "pics/shot.png" }) });

  assert.equal(contentEl.src, undefined, "raw src must be cleared for images");
  assert.match(contentEl.srcdoc, /\/file\/pics\/shot\.png\?full/);
  assert.match(contentEl.srcdoc, /object-fit:contain/);
  // Carries the fit <-> 1:1 (actual-pixel) toggle.
  assert.match(contentEl.srcdoc, /body\.actual/);
  assert.match(contentEl.srcdoc, /addEventListener\('click'/);
});

test("showFile clears a stale image srcdoc when switching to a non-image", () => {
  const { contentEl, getWs } = loadAppJs({
    origin: "http://localhost:9999",
    fetchImpl: fetchSpy(),
    pathname: "/preview1",
  });

  getWs().onmessage({ data: JSON.stringify({ path: "pics/shot.png" }) });
  getWs().onmessage({ data: JSON.stringify({ path: "notes/foo.md" }) });

  assert.equal(contentEl.srcdoc, undefined, "srcdoc must be cleared for non-images");
  assert.equal(contentEl.src, "/file/notes/foo.md?slot=1");
});
