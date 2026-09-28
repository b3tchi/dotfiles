// kwi3 config — Jan's values (migrated from kwi3/config + kwinrc-settings.sh
// by sp004 Task 10, kwi3-234.10, adr0013). Linked by kwi3/dot.yaml to
// ~/.config/kwi3/config.js; the X11 host also honours $KWI3_CONFIG /
// $KWI3_CONFIG_JS pointing straight at this file. See
// https://github.com/b3tchi/kwi3 i3kwin/README.md's Configuration section
// (and i3kwin/examples/config.js for a generic annotated starting point —
// this file is the real values, not the tutorial).
//
// FORMAT: a full JavaScript file (adr0013) - kwi3's ONLY user configuration
// surface, replacing the old i3-syntax ~/.dotfiles/kwi3/config entirely. It
// runs in the SAME scope as core/ and the adapter: the X11 host evaluates it
// directly at startup, install.sh concatenates it into KWin's tiling.js. The
// `kwi3` global below is already defined - nothing to import.
//
// =====================================================================
// kwi3-234.10: settings (this block). Do not add hooks in here - kwi3-234.14
// (the Quickshell runner rule: onWindowAdded for qs-launcher/qs-projects/
// qs-switcher) appends its own kwi3.onWindowAdded(...) calls in the marked
// section below, so the two land as a clean, non-overlapping merge.
// =====================================================================

kwi3.set({
    // Shared with i3/config.common via i3/colors.conf, one source of truth
    // for both — see i3/colors.conf's own header for how kwi3's OLD rcfile
    // reader resolved the `include`; that indirection is gone now (config.js
    // has no include mechanism, and needs none - the values are copied in
    // directly below), but the colours themselves are unchanged.
    palette: {
        focused:         '#152024 #152024 #FDF6E3 #222D31',
        focusedInactive: '#152024 #152024 #707880 #222D31',
        unfocused:       '#222D31 #222D31 #707880 #222D31',
        urgent:          '#CB4B16 #FDF6E3 #16a085 #268BD2',
        placeholder:     '#152024 #152024 #FDF6E3 #152024'
    },

    // The terminal's face and size — the titlebar is one terminal ROW tall
    // and draws in this same face, so it has to match what the session's
    // terminal actually renders in.
    font: 'Iosevka 16',

    // THE MODULE: Jan's session font's real character cell in pixels,
    // measured — not the placeholder in examples/config.js. Every tiled
    // window, split and gap is a whole number of this cell.
    module: [8, 21],

    // The focus ring: thickness 2px, corner radius 4px, colour matching
    // qs-focus-border.py's BC (~/.dotfiles/quickshell/qs-focus-border.py:
    // BW, BR = 2, 4; BC = #16a085) — i3 draws no frame; this is Jan's own,
    // separate program's colours, kept in step here rather than duplicated.
    frame: '2 4 #16a085',

    // The workspace bar's background, served to the bar over i3's own
    // GET_BAR_CONFIG (bar id "kwi3").
    barBackground: '#000000',

    // The modifier every i3kwin binding hangs off. Previously read from
    // kwinrc's Script-i3kwin group (phone/config/kwinrc-settings.sh); that
    // key is retired for i3kwin's own tiling script - this is now the only
    // place that sets it. i3kwinspawn (a separate KWin script, launcher
    // bindings only) still reads its own copy from kwinrc, unaffected by
    // this file - keep the two in step by hand if either changes.
    modifier: 'Alt'

    // focusFrame defaults to true (unset here, matching the old kwi3/config,
    // which never set kwi3_focus_frame either).
});

// =====================================================================
// kwi3-234.14: Quickshell runner rules land here (onWindowAdded for
// qs-launcher / qs-projects / qs-switcher). kwi3-55l.2 widened the same
// rule to qs-clip / qs-notif (the clipboard picker and the notification
// history browser, quickshell/config/ClipHistory.qml + NotifHistory.qml) -
// they open as plain top-level Qt windows exactly like the other three
// (FramelessWindowHint, no dialog/utility window-type hint kwi3 could float
// on automatically - see i3kwin/core/classify.js's `dialog`/`special`
// checks, which never fire for any of these five), so i3 has always needed
// an explicit for_window title rule for them too: i3/config.common's
// `for_window [title="qs-clip"] floating enable, border none, move
// position center` and the identical `qs-notif` line, right beside the
// launcher/projects/switcher ones this rule already mirrors. Before this
// fix the two were tiled on kwi3 - stealing a tile like any ordinary
// window - because the regex below stopped at `switcher`.
//
// All five Quickshell runner/picker windows are ordinary windows to kwi3
// unless told otherwise: floated, undecorated (each draws its own chrome,
// so a tiler titlebar would double up), centred on the tile grid
// (kwi3.grid.center - whole cells, ft008/ft009, matching i3's own `move
// position center`) and focused the moment they are managed (adr0013's own
// sample).
// =====================================================================

kwi3.onWindowAdded({ title: /^qs-(launcher|projects|switcher|clip|notif)$/ }, w => {
    w.float();
    w.noFrame();
    w.moveTo(kwi3.grid.center(w));
    w.focus();
});

// =====================================================================
// kwi3-55l.9 (discovered auditing kwi3-55l.2): the rest of i3/config.common's
// `for_window [...] floating enable` rules — i3/config.common:316-342, every
// non-Quickshell app i3 has ever floated by class/title — mirrored here so
// the same ~27 windows float on kwi3 instead of stealing a tile. Without
// this table only the dialog/utility window-type hint core/classify.js
// already recognises kept a window off the grid; none of these apps carry
// one, so on a kwi3 session every one of them used to tile.
//
// JAN DECISION 2026-09-28 (kwi3-55l.9): port ALL of these, one row per
// i3/config.common `for_window` line, translated faithfully:
//   - i3 criteria are UNANCHORED PCRE substring matches against WM_CLASS
//     class/instance or the window title (i3's own semantics, unrelated to
//     kwi3) — so each RegExp below carries no ^/$, matching
//     core/config-api.js's kwi3MatchField(), which runs pattern.test(value)
//     with no anchoring of its own either.
//   - i3's case-insensitive `(?i)` prefix (System-config-printer.py,
//     virtualbox) becomes the RegExp's own `i` flag — JS regex syntax has no
//     inline (?i) group (confirmed: it throws "Invalid group"), so the flag
//     is the only faithful equivalent.
//   - ONE deliberate narrowing: i3's `System-config-printer.py` has an
//     UNESCAPED `.` (PCRE: any character), ported as `\.` (a literal dot),
//     so e.g. class `System-config-printerXpy` floats on i3 but tiles here.
//     Every other pattern is character-for-character i3's.
//   - i3's per-rule `sticky enable` (i3_help, Lxappearance, Nitrogen, qt5ct,
//     Qtconfig-qt4) is NOT ported — kwi3.onWindowAdded's hook handle
//     (core/reconcile.js kwi3WindowHandle: float/noFrame/moveTo/focus only)
//     has no sticky-equivalent method yet, blocked on kwi3-8kr. Marked
//     `sticky: true` below as a marker for whoever wires kwi3-8kr up; the
//     loop below ignores that field today.
//   - Oblogout's i3 rule is `fullscreen enable`, not `floating enable` — the
//     hook handle has no fullscreen() method either (only float/noFrame/
//     moveTo/focus), so it is floated like the rest of the table instead of
//     dropped. Not a faithful port of "fullscreen", just the closest thing
//     kwi3's hook API can do today; note it if kwi3 ever grows a fullscreen
//     hook method.
//   - i3's per-rule `border ...` clause (pixel 1 / normal / none) has no
//     onWindowAdded equivalent (no border method on the hook handle) and is
//     dropped; a floated window keeps kwi3's normal float decoration.
//   - `for_window [urgent=latest] focus` (i3/config.common:346) is
//     deliberately excluded per the same 2026-09-28 decision — kwi3 has no
//     urgent-window match key and no such auto-focus-on-urgent policy is
//     wanted here.
// =====================================================================

var KWI3_I3_FLOAT_RULES = [
    // match                                              i3 source line   sticky in i3? (kwi3-8kr, not ported)
    { match: { title: /alsamixer/ } },                                  // :316
    { match: { class: /calamares/ } },                                  // :317
    { match: { class: /Clipgrab/ } },                                   // :318
    { match: { title: /File Transfer*/ } },                             // :319
    { match: { class: /fpakman/ } },                                    // :320
    { match: { class: /Galculator/ } },                                 // :321
    { match: { class: /GParted/ } },                                    // :322
    { match: { title: /i3_help/ }, sticky: true },                      // :323
    { match: { class: /Lightdm-settings/ } },                           // :324
    { match: { class: /Lxappearance/ }, sticky: true },                 // :325
    { match: { class: /Manjaro-hello/ } },                              // :326
    { match: { class: /Manjaro Settings Manager/ } },                   // :327
    { match: { title: /MuseScore: Play Panel/ } },                      // :328
    { match: { class: /Nitrogen/ }, sticky: true },                     // :329
    { match: { class: /Oblogout/ } },                                   // :330 (i3: fullscreen enable — floated instead, see above)
    { match: { class: /octopi/ } },                                     // :331
    { match: { title: /About Pale Moon/ } },                            // :332
    { match: { class: /Pamac-manager/ } },                              // :333
    { match: { class: /Pavucontrol/ } },                                // :334
    { match: { class: /qt5ct/ }, sticky: true },                        // :335
    { match: { class: /Qtconfig-qt4/ }, sticky: true },                 // :336
    { match: { class: /Simple-scan/ } },                                // :337
    { match: { class: /System-config-printer\.py/i } },                 // :338 (i3: (?i))
    { match: { class: /Skype/ } },                                      // :339
    { match: { class: /Timeset-gui/ } },                                // :340
    { match: { class: /virtualbox/i } },                                // :341 (i3: (?i))
    { match: { class: /Xfburn/ } }                                      // :342
];

KWI3_I3_FLOAT_RULES.forEach(function (rule) {
    kwi3.onWindowAdded(rule.match, w => { w.float(); });
});
