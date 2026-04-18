#!/usr/bin/env python3
"""Minimal i3 focus border — replaces xborders-patched.
Started and managed by quickshell (config/FocusBorder.qml)."""
import gi, json, subprocess, sys, math, signal, threading
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib
import cairo

BW, BR = 2, 4
BC = (0x16/255, 0xa0/255, 0x85/255)
# Windows to never border (quickshell overlays, rofi, etc.)
IGNORE_CLASSES = {'quickshell', 'Rofi', 'rofi'}


class Border:
    def __init__(self):
        self.win = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.win.set_title('qs-focus-border')
        self.win.set_keep_above(True)
        self.win.set_accept_focus(False)
        self.win.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        visual = self.win.get_screen().get_rgba_visual()
        if visual:
            self.win.set_visual(visual)
        self.win.set_app_paintable(True)
        self.win.connect('draw', self._draw)
        self.win.connect('realize', lambda w: self._passthrough())

    def _passthrough(self):
        """Make window click-through."""
        if self.win.get_realized():
            region = cairo.Region(cairo.RectangleInt(0, 0, 0, 0))
            self.win.get_window().input_shape_combine_region(region, 0, 0)

    def _draw(self, widget, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        a = widget.get_allocation()
        x, y, w, h = BW / 2, BW / 2, a.width - BW, a.height - BW
        cr.new_sub_path()
        cr.arc(x + w - BR, y + BR, BR, -math.pi / 2, 0)
        cr.arc(x + w - BR, y + h - BR, BR, 0, math.pi / 2)
        cr.arc(x + BR, y + h - BR, BR, math.pi / 2, math.pi)
        cr.arc(x + BR, y + BR, BR, math.pi, 3 * math.pi / 2)
        cr.close_path()
        cr.set_source_rgb(*BC)
        cr.set_line_width(BW)
        cr.stroke()

    def update(self, x, y, w, h):
        self.win.move(x - BW, y - BW)
        self.win.resize(w + 2 * BW, h + 2 * BW)
        self._passthrough()
        self.win.show_all()
        self.win.queue_draw()

    def hide(self):
        self.win.hide()


border = Border()


def should_ignore(c):
    """Skip quickshell, rofi, and other overlay windows."""
    props = c.get('window_properties', {})
    cls = props.get('class', '')
    instance = props.get('instance', '')
    title = c.get('name', '')
    if cls in IGNORE_CLASSES or instance in IGNORE_CLASSES:
        return True
    if title.startswith('qs-'):
        return True
    return False


def apply_geom(c):
    if should_ignore(c):
        border.hide()
        return
    r = c.get('rect', {})
    deco_h = c.get('deco_rect', {}).get('height', 0)
    # rect starts below title bar — extend upward to include it
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
    c = e.get('container')
    if not c:
        return
    if change == 'close':
        border.hide()
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
                ['i3-msg', '-t', 'subscribe', '-m', '["window","workspace","binding"]'],
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


def refresh_focused():
    """Re-read focused window geometry from i3 tree (runs in background thread)."""
    def _do_refresh():
        if not _refresh_lock.acquire(blocking=False):
            return  # skip if already refreshing
        try:
            tree = json.loads(
                subprocess.check_output(['i3-msg', '-t', 'get_tree']).decode()
            )

            def walk(node):
                if node.get('focused') and node.get('window'):
                    return node
                for child in node.get('nodes', []) + node.get('floating_nodes', []):
                    result = walk(child)
                    if result:
                        return result
                return None

            found = walk(tree)
            if found:
                GLib.idle_add(apply_geom, found)
            else:
                GLib.idle_add(border.hide)
        except Exception:
            pass
        finally:
            _refresh_lock.release()

    threading.Thread(target=_do_refresh, daemon=True).start()


_orig_handle_event = handle_event


def handle_event(data):
    try:
        e = json.loads(data)
        # Binding events — refresh after any keybinding (catches move/resize/layout)
        if 'binding' in e:
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
