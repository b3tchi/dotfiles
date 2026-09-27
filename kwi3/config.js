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
// qs-launcher / qs-projects / qs-switcher).
//
// The three Quickshell runner dialogs are ordinary windows to kwi3 unless
// told otherwise: floated, undecorated (Overlay.qml draws its own chrome,
// so a tiler titlebar would double up), centred on the tile grid
// (kwi3.grid.center - whole cells, ft008/ft009) and focused the moment
// they are managed (adr0013's own sample).
// =====================================================================

kwi3.onWindowAdded({ title: /^qs-(launcher|projects|switcher)$/ }, w => {
    w.float();
    w.noFrame();
    w.moveTo(kwi3.grid.center(w));
    w.focus();
});
