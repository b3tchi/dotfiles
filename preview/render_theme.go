package main

// Shared presentation for every HTML-rendered *text* preview: markdown
// (renderMarkdown), syntax-highlighted code (renderCode), and the two plain
// fallbacks (renderFallback / renderPlainFallback).
//
// It exists because those renderers previously shipped no presentation at
// all. renderMarkdown emitted a bare `<html><body>` with zero CSS and
// renderCode used chroma's light "github" style, so a text preview painted a
// white page against everything else in this daemon's output, which is
// #111 throughout (the STL viewer, render_stl.go). Text was the gap.
//
// It also adds keyboard zoom, the text analogue of the image tier's
// fit<->1:1 toggle (now native QML, sp022 Tasks 4-5) — text previews had no
// zoom control of any kind. Scaling the root font-size moves prose, tables
// and <pre> together, and unlike a CSS transform it reflows rather than
// clipping.
//
// Both live in the *served document* on purpose: the README's
// browser-fallback contract — "the daemon also serves
// http://127.0.0.1:4200/file/<path>?full; open it in any browser if the GUI
// window isn't available" — means the page has to be self-sufficient, with
// no shell wrapped around it (sp022 Task 8 retired the wry host's own
// shell/script pair entirely, so this was already the only place the dark
// theme and zoom could live).

// previewBG is the single background colour shared by the STL viewer and
// every text preview (the QML native tiers paint their own dark background
// directly, not through this served-document CSS). Named so the value has
// one home; the tests assert against this constant rather than a
// duplicated literal.
const previewBG = "#111"

// textPreviewCSS is the dark palette. It keys off the body classes the
// renderers already set (`markdown-preview`, `code-preview`,
// `preview-fallback`) so one stylesheet covers prose and code without the
// renderers needing to know anything about it.
//
// In renderCode this block is written *after* chroma's own stylesheet so the
// `.chroma` background override lands last and wins. Token colours live on
// separate selectors (`.chroma .k`, `.chroma .c1`, …) and are untouched.
const textPreviewCSS = `
:root{color-scheme:dark}
html,body{margin:0}
html{background:` + previewBG + `}
body{background:` + previewBG + `;color:#d8d8d8;-webkit-text-size-adjust:none}
.chroma{background:transparent}
.preview-truncated{color:#e3a83c;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}

body.code-preview,body.preview-fallback{
  padding:.5rem .75rem;
  font:1rem/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
}
body.code-preview pre,body.preview-fallback pre{margin:0;font:inherit}

body.markdown-preview{
  padding:1rem 1.5rem;
  font:1rem/1.65 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;
}
body.markdown-preview h1,body.markdown-preview h2,body.markdown-preview h3,
body.markdown-preview h4,body.markdown-preview h5,body.markdown-preview h6{
  color:#fff;line-height:1.25;margin:1.4em 0 .5em;
}
body.markdown-preview h1{font-size:1.7em;border-bottom:1px solid #333;padding-bottom:.3em}
body.markdown-preview h2{font-size:1.35em;border-bottom:1px solid #2a2a2a;padding-bottom:.25em}
body.markdown-preview h3{font-size:1.15em}
body.markdown-preview a{color:#6cb6ff}
body.markdown-preview code{
  background:#1e1e1e;padding:.15em .35em;border-radius:3px;
  font:.9em/1.4 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;
}
body.markdown-preview pre{background:#1a1a1a;padding:.75rem;border-radius:4px;overflow-x:auto}
body.markdown-preview pre code{background:none;padding:0}
body.markdown-preview blockquote{margin:0 0 1em;padding:0 1em;color:#9a9a9a;border-left:3px solid #333}
body.markdown-preview table{border-collapse:collapse;margin:1em 0;display:block;overflow-x:auto}
body.markdown-preview th,body.markdown-preview td{border:1px solid #333;padding:.4em .6em;text-align:left}
body.markdown-preview th{background:#1a1a1a;color:#fff}
body.markdown-preview hr{border:0;border-top:1px solid #333;margin:1.5em 0}
body.markdown-preview img{max-width:100%}
body.markdown-preview ul,body.markdown-preview ol{padding-left:1.4em}
`

// textPreviewJS is the keyboard zoom. Bare keys (no modifier) match the house
// style set by imageDoc's z / 1 / space toggle, and avoid relying on
// ctrl-combos that WebKitGTK may claim before the page sees them; ctrl+wheel
// is accepted too since that is the reflex.
//
// The trailing window.focus() on load mirrors imageDoc: the preview renders
// inside the shell's #content iframe, and without an explicit focus the
// iframe document never receives keydown at all.
const textPreviewJS = `
(function(){
  var steps=[50,63,75,88,100,113,125,150,175,200,250,300],base=4,i=base;
  function apply(){document.documentElement.style.fontSize=steps[i]+'%';}
  function step(d){
    var n=i+d;
    if(n<0)n=0;
    if(n>steps.length-1)n=steps.length-1;
    if(n!==i){i=n;apply();}
  }
  addEventListener('keydown',function(e){
    if(e.ctrlKey||e.metaKey||e.altKey)return;
    if(e.key==='+'||e.key==='='){step(1);e.preventDefault();}
    else if(e.key==='-'||e.key==='_'){step(-1);e.preventDefault();}
    else if(e.key==='0'){i=base;apply();e.preventDefault();}
  });
  addEventListener('wheel',function(e){
    if(!e.ctrlKey)return;
    e.preventDefault();
    step(e.deltaY<0?1:-1);
  },{passive:false});
  addEventListener('load',function(){window.focus();});
})();
`

// textPreviewStyle wraps textPreviewCSS in a <style> element for the
// renderers that have no other stylesheet to merge with.
func textPreviewStyle() string {
	return "<style>" + textPreviewCSS + "</style>"
}

// textPreviewScript wraps textPreviewJS in a <script> element. Emitted at the
// end of <body> so the document is parsed before the listeners bind.
func textPreviewScript() string {
	return "<script>" + textPreviewJS + "</script>"
}
