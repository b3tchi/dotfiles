#!/usr/bin/env python3
"""Live region-screenshot selector — compositor-free, via X Shape.

Select a rectangle on the LIVE desktop; the crop is saved to
~/Pictures/screenshots and its file PATH is copied to the clipboard (text, like
tmux copy). Drag, or tap two corners. `w` grabs the whole screen, `Esc` (or
right-click) cancels.

WHY SHAPE, NOT ALPHA (this is the whole design — see [[poc008]]):
bare X11 has no compositor here, so an ARGB window with a translucent interior
renders as a solid BLACK box. The previous overlay worked around that by
freezing the screen to a PNG and showing it fullscreen — which cost a 67-150ms
black blink on every open, because X clears a freshly mapped window to its
background pixel and Qt then needs ~100ms to paint a 2560x1440 image on the
software backend. Warming the process does NOT help ([[poc009]]: a quickshell
warmed 3s still blinked ~100ms).

Instead, this window's BOUNDING shape is cut down to just the rubber-band
outline. Every unselected pixel is simply not part of the window, so the real
desktop shows through — live, undimmed, unfrozen. No compositor involved and no
opaque fullscreen window ever maps, so there is nothing to blink. Same
technique as qs-focus-border.py.

The cost, accepted deliberately: no dim. Shape is binary per pixel; dimming the
desktop outside the selection means BLENDING with what is behind, and blending
is the one thing that genuinely requires a compositor. The i3 "screenshot" mode
+ the bar's hint strip carry the mode signal instead.

Three traps, each of which cost real debugging time — do not "simplify" them:

 1. GDK_BACKEND=x11 is mandatory. WSLg leaves a wayland-0 socket in
    XDG_RUNTIME_DIR and GTK auto-connects to it EVEN WITH WAYLAND_DISPLAY
    UNSET. The window then lands on an invisible compositor: no error, no
    window on $DISPLAY, zero events — and a measurement that FALSELY PASSES.
 2. Input must come from a seat GRAB, never from the input shape. X intersects
    the INPUT region with the BOUNDING region, so a window shaped to an outline
    receives nothing in its hollow middle no matter what
    input_shape_combine_region says. (This is what slop does too.)
 3. The grab must run AFTER the map (idle callback), never from 'realize', and
    >=1px must stay shaped — an empty bounding region makes the window
    non-viewable and the grab fails "not-viewable".

Launched by qs-screenshot.sh. Usage: qs-region.py [--whole]
"""
import os
import subprocess
import sys
import time

import gi

gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib  # noqa: E402
import cairo  # noqa: E402

# CONTRACT: i3/picom.conf matches this literal in focus-exclude and
# unredir-if-possible-exclude (sp012 T5). picom matches BY NAME — renaming this
# silently stops the match, and the overlay gets inactive-dim'd on native :0
# with no error (the trap commit 935e568 already hit once).
TITLE = 'qs-region'

# The i3 MODE colour (Bar.qml:576/589), so the outline and the bar's mode hint
# agree. NOT #16a085 — that is the workspace-focused green.
ACCENT_HEX = '#cb4b16'
ACCENT = (0xcb / 255, 0x4b / 255, 0x16 / 255)

BW = 2                      # outline stroke width
MIN_SEL = 3                 # below this, a "drag" is really a stray click
OUTDIR = os.path.expanduser('~/Pictures/screenshots')


def normalise(x0, y0, x1, y1, sw, sh):
    """Two drag corners -> (x, y, w, h), always positive, always on-screen.

    Callers hand this raw pointer coords, which are hostile: a right-to-left
    drag makes x1 < x0, and a drag released past the edge goes out of bounds.
    Negative or off-screen geometry reaching `scrot -a` is a hard failure, so
    normalise here rather than at each call site.
    """
    x_lo, x_hi = sorted((int(x0), int(x1)))
    y_lo, y_hi = sorted((int(y0), int(y1)))
    x_lo = max(0, min(x_lo, sw))
    x_hi = max(0, min(x_hi, sw))
    y_lo = max(0, min(y_lo, sh))
    y_hi = max(0, min(y_hi, sh))
    return x_lo, y_lo, x_hi - x_lo, y_hi - y_lo


def is_selection(w, h):
    """A real drag, or a stray click? Guards against writing a 0x0 PNG."""
    return w >= MIN_SEL and h >= MIN_SEL


def shot_path(outdir=OUTDIR):
    """ft006 api_surface: ~/Pictures/screenshots/shot_<YYYYmmdd-HHMMSS>.png"""
    return os.path.join(outdir, time.strftime('shot_%Y%m%d-%H%M%S.png'))


def capture(x, y, w, h, outdir=OUTDIR):
    """Grab a screen region to a file and put the PATH on the clipboard.

    Returns the path. Raises on failure — callers must release the grab first;
    a held grab plus a traceback would strand the pointer.
    """
    os.makedirs(outdir, exist_ok=True)
    path = shot_path(outdir)
    subprocess.run(['scrot', '-o', '-a', '%d,%d,%d,%d' % (x, y, w, h), path],
                   check=True)
    subprocess.run(['xclip', '-selection', 'clipboard'],
                   input=path.encode(), check=True)
    return path


class Region:
    def __init__(self, whole=False):
        self.x0 = self.y0 = self.x1 = self.y1 = 0
        self.dragging = False
        self.clicks = 0          # 2-tap mode: 1 = corner A placed
        self.status = 1          # non-zero until a path completes cleanly
        self.whole = whole

        scr = Gdk.Screen.get_default()
        self.W, self.H = scr.get_width(), scr.get_height()

        self.win = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.win.set_title(TITLE)
        self.win.set_keep_above(True)
        self.win.set_app_paintable(True)
        self.win.move(0, 0)
        self.win.resize(self.W, self.H)
        self.win.add_events(Gdk.EventMask.BUTTON_PRESS_MASK
                            | Gdk.EventMask.BUTTON_RELEASE_MASK
                            | Gdk.EventMask.POINTER_MOTION_MASK
                            | Gdk.EventMask.KEY_PRESS_MASK)
        self.win.connect('draw', self._draw)
        self.win.connect('realize', lambda w: self._shape())
        self.win.connect('button-press-event', self._press)
        self.win.connect('motion-notify-event', self._motion)
        self.win.connect('button-release-event', self._release)
        self.win.connect('key-press-event', self._key)
        self.win.show_all()

    # ── shape ────────────────────────────────────────────────────────────
    def _region(self):
        """Rasterise the outline, then turn its pixels into the window's
        BOUNDING shape. Everything else stops being part of the window."""
        surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, self.W, self.H)
        cr = cairo.Context(surf)
        cr.set_source_rgba(1, 1, 1, 1)
        if self.dragging:
            x, y, w, h = self._rect()
            cr.rectangle(x + BW / 2, y + BW / 2, max(w - BW, 1), max(h - BW, 1))
            cr.set_line_width(BW)
            cr.stroke()
        else:
            # Keep >=1px: an empty bounding region makes the window
            # non-viewable and the seat grab then fails "not-viewable".
            cr.rectangle(0, 0, 1, 1)
            cr.fill()
        surf.flush()
        return Gdk.cairo_region_create_from_surface(surf)

    def _shape(self):
        gw = self.win.get_window()
        if gw:
            gw.shape_combine_region(self._region(), 0, 0)

    def _draw(self, _w, cr):
        # The bounding shape clips everything but the outline, so a flat fill
        # is enough — only the shaped pixels survive.
        cr.set_source_rgb(*ACCENT)
        cr.paint()
        return True

    # ── input (via the grab) ─────────────────────────────────────────────
    def grab(self):
        """Must run AFTER the map — grabbing from 'realize' gets
        "not-viewable" because the window exists but is not yet on screen."""
        gw = self.win.get_window()
        dpy = Gdk.Display.get_default()
        cur = Gdk.Cursor.new_from_name(dpy, 'crosshair')
        st = dpy.get_default_seat().grab(
            gw, Gdk.SeatCapabilities.ALL, True, cur, None, None, None)
        if st != Gdk.GrabStatus.SUCCESS:
            print('qs-region: seat grab failed: %s' % st.value_nick,
                  file=sys.stderr)
            self.status = 1
            Gtk.main_quit()
            return False
        if self.whole:
            # --whole: no selection needed, shoot the screen and go.
            GLib.idle_add(self._shoot, 0, 0, self.W, self.H)
        return False

    def _rect(self):
        return normalise(self.x0, self.y0, self.x1, self.y1, self.W, self.H)

    def _press(self, _w, e):
        if e.button != 1:
            self.cancel()
            return True
        if self.clicks == 0:
            self.x0, self.y0 = int(e.x_root), int(e.y_root)
            self.x1, self.y1 = self.x0, self.y0
            self.dragging = True
        else:
            self.x1, self.y1 = int(e.x_root), int(e.y_root)
        return True

    def _motion(self, _w, e):
        if not self.dragging:
            return False
        self.x1, self.y1 = int(e.x_root), int(e.y_root)
        self._shape()
        self.win.queue_draw()
        return True

    def _release(self, _w, e):
        if e.button != 1 or not self.dragging:
            return False
        self.x1, self.y1 = int(e.x_root), int(e.y_root)
        x, y, w, h = self._rect()
        if is_selection(w, h):
            self._shoot(x, y, w, h)
        elif self.clicks == 0:
            # Not a drag — arm 2-tap mode and wait for the second corner.
            self.clicks = 1
        else:
            self.cancel()
        return True

    def _key(self, _w, e):
        if e.keyval == Gdk.KEY_Escape:
            self.cancel()
        elif e.keyval in (Gdk.KEY_w, Gdk.KEY_W):
            self._shoot(0, 0, self.W, self.H)
        return True

    # ── exits ────────────────────────────────────────────────────────────
    def _shoot(self, x, y, w, h):
        """Drop the overlay, THEN capture — so the outline is never in the
        shot, and nothing was captured up front if the user cancels."""
        self.win.hide()
        Gdk.Display.get_default().sync()
        time.sleep(0.08)          # let X repaint the vacated region
        try:
            path = capture(x, y, w, h)
        except Exception as exc:  # scrot/xclip missing or failing
            print('qs-region: capture failed: %s' % exc, file=sys.stderr)
            self.status = 1
        else:
            print('SAVED %s (%dx%d)' % (path, w, h))
            self.status = 0
        Gtk.main_quit()
        return False

    def cancel(self):
        self.status = 0           # cancelling is a clean exit, not an error
        Gtk.main_quit()


def main():
    if os.environ.get('GDK_BACKEND') != 'x11':
        # Not fatal on its own, but on WSL the wayland-0 socket silently wins
        # and the window vanishes onto an idle compositor. Fail loudly rather
        # than debug an invisible window.
        print('qs-region: GDK_BACKEND must be x11 (see module docstring)',
              file=sys.stderr)
        return 1
    app = Region(whole='--whole' in sys.argv)
    GLib.idle_add(app.grab)       # after the map, never from realize
    Gtk.main()
    return app.status


if __name__ == '__main__':
    sys.exit(main())
