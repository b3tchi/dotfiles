// ==UserScript==
// @name        Double-tap seek
// @description YouTube-style double-tap on video sides to jump -/+ STEP seconds, with overlay
// @match       *://*/*
// @run-at      document-start
// @grant       none
// ==/UserScript==
// Install: Tampermonkey/Violentmonkey -> create new script -> paste this file.
const STEP = 19;     // seconds
const SIDE = 0.35;   // side zone width (35% each side)
const TOP = 0.20;    // ignore top 20% (title, top buttons)
const BOTTOM = 0.25; // ignore bottom 25% (seek bar, controls)
const DT = 300;      // double-tap window, ms
let last = 0, lastSide = 0;
let box, boxSide = 0, total = 0, hideTimer;

function hit(x, y) {
  for (const v of document.querySelectorAll('video')) {
    const r = v.getBoundingClientRect();
    if (x >= r.left && x <= r.right && y >= r.top && y <= r.bottom) {
      const fy = (y - r.top) / r.height;
      if (fy < TOP || fy > 1 - BOTTOM) return null;  // controls area: page handles
      const f = (x - r.left) / r.width;
      return { v, side: f < SIDE ? -1 : f > 1 - SIDE ? 1 : 0 };
    }
  }
  return null;
}

function show(v, side) {
  if (!box) {
    box = document.createElement('div');
    box.style.cssText =
      'position:fixed;z-index:2147483647;pointer-events:none;' +
      'background:rgba(0,0,0,.6);color:#fff;font:bold 20px sans-serif;' +
      'padding:10px 18px;border-radius:999px;transform:translate(-50%,-50%);' +
      'transition:opacity .2s;opacity:0';
  }
  const fs = document.fullscreenElement;
  const host = fs && fs.tagName !== 'VIDEO' ? fs : document.body;
  if (box.parentNode !== host) host.appendChild(box);

  if (side !== boxSide) total = 0;
  boxSide = side;
  total += STEP;
  box.textContent = side < 0 ? `« ${total}s` : `${total}s »`;

  const r = v.getBoundingClientRect();
  box.style.top = r.top + r.height / 2 + 'px';
  box.style.left = r.left + r.width * (side < 0 ? 0.18 : 0.82) + 'px';
  box.style.opacity = '1';

  clearTimeout(hideTimer);
  hideTimer = setTimeout(() => {
    box.style.opacity = '0';
    total = 0;
    boxSide = 0;
  }, 800);
}

function handler(e) {
  const t = e.changedTouches?.[0] || e;
  const h = hit(t.clientX, t.clientY);
  if (!h || !h.side) return;           // middle, controls or outside: page handles
  e.preventDefault();
  e.stopImmediatePropagation();         // page never sees tap -> no pause
  if (e.type !== 'pointerup') return;
  const now = Date.now();
  if (now - last < DT && lastSide === h.side) {
    h.v.currentTime += h.side * STEP;   // keep tapping = more jumps
    show(h.v, h.side);
  }
  last = now;
  lastSide = h.side;
}

for (const ev of ['pointerdown', 'pointerup', 'mousedown', 'mouseup',
                  'touchstart', 'touchend', 'click', 'dblclick']) {
  window.addEventListener(ev, handler, { capture: true, passive: false });
}
