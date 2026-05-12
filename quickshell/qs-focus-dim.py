#!/usr/bin/env python3
"""Minimal i3 focus dim — sibling to qs-focus-border.py.
Draws a 30% black overlay covering everything outside the focused window.
Started and managed by quickshell (config/FocusDim.qml)."""
import gi, signal, sys, fcntl, os
import json, subprocess, threading
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk, GLib
import cairo

_lock_path = os.path.join(
    os.environ.get('XDG_RUNTIME_DIR', '/tmp'), 'qs-focus-dim.lock'
)
_lock_fp = open(_lock_path, 'w')
try:
    fcntl.flock(_lock_fp.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit(0)
_lock_fp.write(str(os.getpid()))
_lock_fp.flush()

DIM_ALPHA = 0.3

IGNORE_CLASSES = {'quickshell', 'Rofi', 'rofi'}

# Current focused-window rect in root (screen) coords; None means hide cut-out
focus_rect = None


def should_ignore(c):
    props = c.get('window_properties', {})
    cls = props.get('class', '')
    instance = props.get('instance', '')
    title = c.get('name', '')
    if cls in IGNORE_CLASSES or instance in IGNORE_CLASSES:
        return True
    if title.startswith('qs-'):
        return True
    return False


def refresh_focused():
    def _do():
        try:
            tree = json.loads(
                subprocess.check_output(
                    ['i3-msg', '-t', 'get_tree'], timeout=2
                ).decode()
            )

            def walk(node, parents):
                if node.get('focused') and node.get('window'):
                    return node, parents
                for child in node.get('nodes', []) + node.get('floating_nodes', []):
                    r = walk(child, parents + [node])
                    if r:
                        return r
                return None

            result = walk(tree, [])
            global focus_rect
            if not result:
                focus_rect = None
            else:
                leaf, parents = result
                if should_ignore(leaf) or leaf.get('fullscreen_mode', 0) > 0:
                    focus_rect = None
                else:
                    r = leaf.get('rect', {})
                    deco_h = leaf.get('deco_rect', {}).get('height', 0)
                    in_tabbed = any(p.get('layout') in ('tabbed', 'stacked') for p in parents)
                    direct_in_tabbed = parents and parents[-1].get('layout') in ('tabbed', 'stacked')
                    if in_tabbed and not direct_in_tabbed:
                        deco_h = 0
                    focus_rect = (
                        r.get('x', 0),
                        r.get('y', 0) - deco_h,
                        r.get('width', 0),
                        r.get('height', 0) + deco_h,
                    )
            GLib.idle_add(_redraw_all)
        except Exception as exc:
            print(f"qs-focus-dim: refresh_focused: {exc}",
                  file=sys.stderr, flush=True)
    threading.Thread(target=_do, daemon=True).start()


def _redraw_all():
    for o in overlays:
        o.win.queue_draw()
    return False


def subscribe():
    import time
    while True:
        try:
            proc = subprocess.Popen(
                ['i3-msg', '-t', 'subscribe', '-m',
                 '["window","workspace","binding"]'],
                stdout=subprocess.PIPE, text=True
            )
            for _ in proc.stdout:
                refresh_focused()
            proc.wait()
        except Exception as exc:
            print(f"qs-focus-dim: subscribe: {exc}",
                  file=sys.stderr, flush=True)
        time.sleep(1)


class DimOverlay:
    def __init__(self, monitor):
        self.monitor = monitor
        self.win = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.win.set_title('qs-focus-dim')
        self.win.set_keep_above(True)
        self.win.set_accept_focus(False)
        self.win.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
        visual = self.win.get_screen().get_rgba_visual()
        if visual:
            self.win.set_visual(visual)
        self.win.set_app_paintable(True)
        self.win.connect('draw', self._draw)
        self.win.connect('realize', lambda w: self._passthrough())
        g = monitor.get_geometry()
        self.win.move(g.x, g.y)
        self.win.resize(g.width, g.height)
        self.win.show_all()

    def _passthrough(self):
        if self.win.get_realized():
            region = cairo.Region(cairo.RectangleInt(0, 0, 0, 0))
            self.win.get_window().input_shape_combine_region(region, 0, 0)

    def _draw(self, widget, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE)
        cr.set_source_rgba(0, 0, 0, 0)
        cr.paint()
        cr.set_operator(cairo.OPERATOR_OVER)
        a = widget.get_allocation()
        cr.set_source_rgba(0, 0, 0, DIM_ALPHA)
        if focus_rect is None:
            cr.rectangle(0, 0, a.width, a.height)
            cr.fill()
            return
        fx, fy, fw, fh = focus_rect
        g = self.monitor.get_geometry()
        fx -= g.x; fy -= g.y
        if fx + fw <= 0 or fy + fh <= 0 or fx >= a.width or fy >= a.height:
            cr.rectangle(0, 0, a.width, a.height)
            cr.fill()
            return
        cx = max(0, fx); cy = max(0, fy)
        cw = min(a.width, fx + fw) - cx
        ch = min(a.height, fy + fh) - cy
        cr.rectangle(0, 0, a.width, cy)
        cr.rectangle(0, cy + ch, a.width, a.height - (cy + ch))
        cr.rectangle(0, cy, cx, ch)
        cr.rectangle(cx + cw, cy, a.width - (cx + cw), ch)
        cr.fill()


display = Gdk.Display.get_default()
if display is None:
    print("qs-focus-dim: no display", file=sys.stderr, flush=True)
    sys.exit(1)

overlays = [DimOverlay(display.get_monitor(i))
            for i in range(display.get_n_monitors())]

mouse_held = False
mouse_poll_id = None


def mouse_poll():
    global mouse_held, mouse_poll_id
    if not mouse_held:
        mouse_poll_id = None
        refresh_focused()
        return False
    refresh_focused()
    return True


def mouse_monitor():
    import struct
    try:
        from Xlib import display as xdisplay
        from Xlib.ext import xinput
    except ImportError:
        print("qs-focus-dim: python-xlib not installed; "
              "mouse-drag polling disabled", file=sys.stderr, flush=True)
        return
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
    global mouse_held, mouse_poll_id
    while True:
        event = d.next_event()
        evtype = getattr(event, "evtype", None)
        data = getattr(event, "data", None)
        if not isinstance(data, (bytes, bytearray)) or len(data) < hdr.size:
            continue
        _, _, button = hdr.unpack_from(data, 0)
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
threading.Thread(target=subscribe, daemon=True).start()
threading.Thread(target=mouse_monitor, daemon=True).start()
Gtk.main()
