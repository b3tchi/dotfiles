#!/usr/bin/env python3
"""Minimal i3 focus border — replaces xborders-patched.
Started and managed by quickshell (config/FocusBorder.qml)."""
import gi, json, subprocess, sys, math, signal, threading, fcntl, os
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib
import cairo

# Single-instance lock. Orphaned instances (parent quickshell crashed) keep
# drawing stale borders, producing the union of multiple frames at different
# sizes — looks like the frame wraps a parent container.
# Lock is per display so concurrent sessions (local + xrdp) don't block
# each other's helper.
_dpy = os.environ.get('DISPLAY') or os.environ.get('WAYLAND_DISPLAY') or '0'
_dpy = ''.join(c if c.isalnum() else '_' for c in _dpy)
_lock_path = os.path.join(
    os.environ.get('XDG_RUNTIME_DIR', '/tmp'), 'qs-focus-border.%s.lock' % _dpy
)
_lock_fp = open(_lock_path, 'w')
try:
    fcntl.flock(_lock_fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)
_lock_fp.write(str(os.getpid()))
_lock_fp.flush()

BW, BR = 2, 4
BC = (0x16/255, 0xa0/255, 0x85/255)
# Windows to never border (quickshell overlays, rofi, etc.)
IGNORE_CLASSES = {'quickshell', 'Rofi', 'rofi'}
IGNORE_TITLES = {'qs-focus-border', 'qs-focus-dim'}
# When any of these overlays are mapped, suppress the border entirely —
# focus may still report the underlying window during the brief window
# between binding event and overlay grabbing focus, leaving a frame
# visible around whatever was focused before mod+d / mod+p / mod+tab.
SUPPRESS_WHEN_PRESENT_TITLES = {'qs-launcher', 'qs-projects', 'qs-switcher'}
# i3 modes whose overlay covers the screen as a dock layer (screenshot
# selector). While one is active refreshes are blocked — but the border is
# NOT hidden at mode enter: the overlay takes ~0.5s to map (scrot + startup)
# and hiding early blinks. The hide lands on the overlay's window::new event.
SUPPRESS_MODES = {'screenshot'}


class Border:
    """Compositor-free border: instead of an ARGB window with a transparent
    interior (which renders as a solid black box on bare X11 — that's what
    used to force picom onto xrdp/wsl), the window's BOUNDING shape is cut
    down to just the ring. No alpha involved, works with or without a
    compositor. Rounded corners survive via region-from-surface."""

    def __init__(self):
        self.win = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.win.set_title('qs-focus-border')
        self.win.set_keep_above(True)
        self.win.set_accept_focus(False)
        self.win.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        self.win.set_app_paintable(True)
        self.win.connect('draw', self._draw)
        self.win.connect('realize', lambda w: self._passthrough())

    def _passthrough(self):
        """Make window click-through."""
        if self.win.get_realized():
            region = cairo.Region(cairo.RectangleInt(0, 0, 0, 0))
            self.win.get_window().input_shape_combine_region(region, 0, 0)

    def _ring_path(self, cr, w, h):
        x, y, ww, hh = BW / 2, BW / 2, w - BW, h - BW
        cr.new_sub_path()
        cr.arc(x + ww - BR, y + BR, BR, -math.pi / 2, 0)
        cr.arc(x + ww - BR, y + hh - BR, BR, 0, math.pi / 2)
        cr.arc(x + BR, y + hh - BR, BR, math.pi / 2, math.pi)
        cr.arc(x + BR, y + BR, BR, math.pi, 3 * math.pi / 2)
        cr.close_path()

    def _ring_region(self, w, h):
        """Rasterize the ring stroke and turn pixels with alpha into the
        window's bounding shape."""
        surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, w, h)
        cr = cairo.Context(surf)
        cr.set_source_rgba(1, 1, 1, 1)
        self._ring_path(cr, w, h)
        cr.set_line_width(BW)
        cr.stroke()
        surf.flush()
        return Gdk.cairo_region_create_from_surface(surf)

    def _draw(self, widget, cr):
        # The shape clips everything but the ring — solid fill is enough.
        cr.set_source_rgb(*BC)
        cr.paint()

    def update(self, x, y, w, h):
        W, H = w + 2 * BW, h + 2 * BW
        self.win.move(x - BW, y - BW)
        self.win.resize(W, H)
        self._passthrough()
        self.win.show_all()
        gdk_win = self.win.get_window()
        if gdk_win:
            gdk_win.shape_combine_region(self._ring_region(W, H), 0, 0)
        self.win.queue_draw()

    def hide(self):
        self.win.hide()


border = Border()

# While a SUPPRESS_MODES mode is active the border (keep-above notification)
# would restack above the overlay dock on every refresh — binding events and
# the 100ms mouse-drag poll fire constantly during a selection drag. Block
# all refreshes until the mode ends. Only touched on the GLib main thread
# (all event/poll paths run there).
mode_suppressed = False


def should_ignore(c):
    """Skip quickshell, rofi, and other overlay windows."""
    props = c.get('window_properties', {})
    cls = props.get('class', '')
    instance = props.get('instance', '')
    title = c.get('name', '')
    if cls in IGNORE_CLASSES or instance in IGNORE_CLASSES:
        return True
    if title in IGNORE_TITLES:
        return True
    return False


def apply_geom(c, parents):
    # mode_suppressed re-checked here: a refresh already in flight when the
    # mode started must not restack the border. Skip without hiding — the
    # border stays as-is until the overlay's window::new hides it.
    if mode_suppressed:
        return
    if should_ignore(c):
        border.hide()
        return
    r = c.get('rect', {})
    deco_h = c.get('deco_rect', {}).get('height', 0)
    # rect starts below title bar — extend upward to include it.
    # Skip the extension when leaf is inside splith/splitv that is itself
    # inside tabbed/stacked: i3 reports deco_h=24 for the leaf even though
    # no per-leaf title is actually rendered (the tab strip belongs to the
    # splith intermediate, not this leaf).
    in_tabbed = any(p.get('layout') in ('tabbed', 'stacked') for p in parents)
    direct_in_tabbed = parents and parents[-1].get('layout') in ('tabbed', 'stacked')
    if in_tabbed and not direct_in_tabbed:
        deco_h = 0
    x = r.get('x', 0)
    y = r.get('y', 0) - deco_h
    w = r.get('width', 0)
    h = r.get('height', 0) + deco_h
    if w > 0 and h > 0:
        border.update(x, y, w, h)


def handle_event(data):
    try:
        e = json.loads(data)
    except Exception:
        return
    change = e.get('change')
    # Workspace events
    if change == 'focus' and 'current' in e and 'container' not in e:
        border.hide()
        cur = e.get('current', {})
        nodes = cur.get('nodes', []) + cur.get('floating_nodes', [])
        if nodes:
            refresh_focused()
        return
    # i3 "mode" change. A mode event has only 'change' (the mode name) — no
    # container/current/binding. Entering a SUPPRESS_MODES mode arms
    # suppression (no hide — see SUPPRESS_MODES comment). Any other mode,
    # including "default", refreshes: leaving the screenshot mode must redraw
    # because the overlay never emits a focus event, and modes like "resize"
    # keep the live-refresh behavior.
    if 'container' not in e and 'current' not in e and 'binding' not in e:
        global mode_suppressed
        if change in SUPPRESS_MODES:
            mode_suppressed = True
        else:
            mode_suppressed = False
            refresh_focused()
        return
    c = e.get('container')
    if not c:
        return
    if change == 'new':
        # A quickshell window mapped (screenshot selector dock — PanelWindow
        # has no title, so its event name is the default "quickshell" — or a
        # qs-* titled launcher overlay). It may cover the screen and the
        # border would float above it — hide exactly now, not at mode enter,
        # so the border stays up during the scrot/startup gap. The follow-up
        # refresh restores the border after a plain bar restart (no qs-*
        # overlay in the tree then); under an active SUPPRESS_MODES mode
        # it's a no-op.
        name = c.get('name') or ''
        cls = (c.get('window_properties') or {}).get('class') or ''
        if name.startswith('qs-') or name == 'quickshell' or cls == 'quickshell':
            border.hide()
            refresh_focused()
        return
    if change == 'close':
        # Redraw on whatever i3 refocuses after the close. Normally a following
        # window::focus event would do this, but if the next window was already
        # focused (e.g. the screenshot overlay pre-focuses its caller before
        # quitting) no focus event fires — so the border would vanish. Refresh
        # explicitly. refresh_focused() hides if nothing focusable remains.
        border.hide()
        refresh_focused()
    elif change == 'focus':
        border.hide()
        if c.get('fullscreen_mode', 0) > 0:
            pass
        else:
            refresh_focused()
    elif change in ('move', 'floating'):
        refresh_focused()
    elif change == 'fullscreen_mode':
        if c.get('fullscreen_mode', 0) > 0:
            border.hide()
        else:
            refresh_focused()


def subscribe():
    """Subscribe to i3 window/workspace/binding events; reconnects on failure."""
    while True:
        try:
            proc = subprocess.Popen(
                ['i3-msg', '-t', 'subscribe', '-m', '["window","workspace","binding","mode"]'],
                stdout=subprocess.PIPE, text=True
            )
            for line in proc.stdout:
                line = line.strip()
                if line:
                    GLib.idle_add(handle_event, line)
            proc.wait()
        except Exception:
            pass
        import time
        time.sleep(1)


_refresh_lock = threading.Lock()


def _has_overlay_present(node):
    if node.get('name', '') in SUPPRESS_WHEN_PRESENT_TITLES:
        return True
    for child in node.get('nodes', []) + node.get('floating_nodes', []):
        if _has_overlay_present(child):
            return True
    return False


def refresh_focused():
    """Re-read focused window geometry from i3 tree (runs in background thread)."""
    if mode_suppressed:
        return

    def _do_refresh():
        if not _refresh_lock.acquire(blocking=False):
            return  # skip if already refreshing
        try:
            tree = json.loads(
                subprocess.check_output(['i3-msg', '-t', 'get_tree']).decode()
            )

            if _has_overlay_present(tree):
                GLib.idle_add(border.hide)
                return

            def walk(node, parents):
                if node.get('focused') and node.get('window'):
                    return node, parents
                for child in node.get('nodes', []) + node.get('floating_nodes', []):
                    result = walk(child, parents + [node])
                    if result:
                        return result
                return None

            result = walk(tree, [])
            if result:
                leaf, parents = result
                GLib.idle_add(apply_geom, leaf, parents)
            else:
                GLib.idle_add(border.hide)
        except Exception:
            pass
        finally:
            _refresh_lock.release()

    threading.Thread(target=_do_refresh, daemon=True).start()


_orig_handle_event = handle_event


def handle_event(data):
    global mode_suppressed
    try:
        e = json.loads(data)
        # Binding events — refresh after any keybinding (catches move/resize/layout)
        if 'binding' in e:
            cmd = (e.get('binding') or {}).get('command') or ''
            # The binding that ENTERS a suppress mode arrives BEFORE the mode
            # event — arm suppression here already, or this very refresh can
            # land in between and restack the border above the overlay.
            if any('mode "%s"' % m in cmd or 'mode %s' % m in cmd
                   for m in SUPPRESS_MODES):
                mode_suppressed = True
                return
            refresh_focused()
            return
    except Exception:
        pass
    _orig_handle_event(data)


mouse_held = False
mouse_poll_id = None


def mouse_poll():
    """Poll geometry while mouse button is held (drag resize/move)."""
    global mouse_held, mouse_poll_id
    if not mouse_held:
        mouse_poll_id = None
        refresh_focused()  # final refresh on release
        return False
    refresh_focused()
    return True


def mouse_monitor():
    """Track mouse button press/release via XI2 raw events."""
    global mouse_held, mouse_poll_id
    import struct
    from Xlib import display as xdisplay
    from Xlib.ext import xinput

    d = xdisplay.Display()
    if not d.has_extension("XInputExtension"):
        return

    root = d.screen().root
    root.xinput_select_events([
        (xinput.AllMasterDevices,
         xinput.RawButtonPressMask | xinput.RawButtonReleaseMask),
    ])
    d.sync()

    hdr = struct.Struct("<HII")
    while True:
        event = d.next_event()
        evtype = getattr(event, "evtype", None)
        data = getattr(event, "data", None)
        if not isinstance(data, (bytes, bytearray)) or len(data) < hdr.size:
            continue
        _, _, button = hdr.unpack_from(data, 0)
        # Only track left button (1) for drag operations
        if button != 1:
            continue
        if evtype == xinput.RawButtonPress:
            mouse_held = True
            if mouse_poll_id is None:
                mouse_poll_id = GLib.timeout_add(100, mouse_poll)
        elif evtype == xinput.RawButtonRelease:
            mouse_held = False


signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
signal.signal(signal.SIGINT, lambda *a: sys.exit(0))

GLib.idle_add(refresh_focused)
t = threading.Thread(target=subscribe, daemon=True)
t.start()
t_mouse = threading.Thread(target=mouse_monitor, daemon=True)
t_mouse.start()
Gtk.main()
