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
    c = e.get('container')
    if not c:
        return
    change = e.get('change')
    if change == 'close':
        border.hide()
    elif change in ('focus', 'move', 'floating'):
        if c.get('fullscreen_mode', 0) > 0:
            border.hide()
        else:
            apply_geom(c)
    elif change == 'fullscreen_mode':
        if c.get('fullscreen_mode', 0) > 0:
            border.hide()
        else:
            apply_geom(c)


def subscribe():
    """Subscribe to i3 window events; reconnects on failure."""
    while True:
        try:
            proc = subprocess.Popen(
                ['i3-msg', '-t', 'subscribe', '-m', '["window"]'],
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


def init_focused():
    """Find currently focused window on startup."""
    try:
        tree = json.loads(
            subprocess.check_output(['i3-msg', '-t', 'get_tree']).decode()
        )

        def walk(node):
            if node.get('focused') and node.get('window'):
                apply_geom(node)
                return True
            for child in node.get('nodes', []) + node.get('floating_nodes', []):
                if walk(child):
                    return True
            return False

        walk(tree)
    except Exception:
        pass


signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
signal.signal(signal.SIGINT, lambda *a: sys.exit(0))

GLib.idle_add(init_focused)
t = threading.Thread(target=subscribe, daemon=True)
t.start()
Gtk.main()
