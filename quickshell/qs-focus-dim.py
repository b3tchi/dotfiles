#!/usr/bin/env python3
"""Minimal i3 focus dim — sibling to qs-focus-border.py.
Draws a 30% black overlay covering everything outside the focused window.
Started and managed by quickshell (config/FocusDim.qml)."""
import gi, signal, sys, fcntl, os
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, Gdk
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
        cr.rectangle(0, 0, a.width, a.height)
        cr.fill()


display = Gdk.Display.get_default()
if display is None:
    print("qs-focus-dim: no display", file=sys.stderr, flush=True)
    sys.exit(1)

overlays = [DimOverlay(display.get_monitor(i))
            for i in range(display.get_n_monitors())]

signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
signal.signal(signal.SIGINT, lambda *a: sys.exit(0))

Gtk.main()
