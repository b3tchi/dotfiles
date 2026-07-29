#!/usr/bin/env python3
"""Minimal i3 focus border — replaces xborders-patched.
Started and managed by quickshell (config/FocusBorder.qml)."""
import gi, json, subprocess, sys, math, signal, threading, fcntl, os, time
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
# Frame colour while a KEY-CAPTURING mode is active (dotfiles-5u6m). In these
# modes bare letters are WM commands, not input — the red ring is the standing
# reminder that the next `q` quits the mode instead of reaching the terminal
# under the cursor. The bar's mode pill says the same thing, but the frame is
# where the eye already is while navigating.
MODE_BC = (0xcb/255, 0x4b/255, 0x16/255)   # ModeBarTheme.highlight
# i3 modes that still colour the frame. "screenshot" is here so the ring around
# the currently-focused window doubles as "this is what `w` would capture" — it
# changes again mid-gesture via "screenshot-drag" (see SUPPRESS_MODES below).
#
# `nav` is NOT here any more: it left i3 entirely in the sp020 T7 cutover, and
# the daemon's layer feed replaced it (see hotkeyd_layer_monitor below). Any i3
# mode listed here still works the old way.
COLOR_MODES = {'screenshot'}

# hotkeyd layers that mean the same thing as a colouring i3 mode did: bare
# letters are WM commands, not input. Anything other than "default" qualifies —
# a layer exists precisely because it captures keys.
HOTKEYD_COLORS_ANY_LAYER = True

# ...except the SILENT ones (dotfiles-hwds.44). The alt-tab switcher is a
# held-modifier gesture that already puts a full-screen overlay on the display
# saying what it will do, so colouring the ring adds no information and makes
# `$mod+w` visually louder than `$mod+d` / `$mod+p`, which open an overlay and
# change nothing else. The ring is a WARNING that bare letters have become WM
# commands; spending it on a gesture that cannot surprise anyone is how a
# warning stops being read.
#
# MIRRORS ModeBarTheme.silentModes (quickshell/config/Common/ModeBarTheme.qml),
# which suppresses the bar's mode strip for the same set. Two files because two
# languages — keep them in step; each names the other.
#
# Silence is opt-IN: an unclassified layer still colours the ring, because a
# spurious warning is cheaper than a missing one.
SILENT_LAYERS = {'switcher'}


def layer_colours_ring(layer):
    """Should the daemon's current layer paint the ring in MODE_BC?"""
    return (HOTKEYD_COLORS_ANY_LAYER
            and layer != 'default'
            and layer not in SILENT_LAYERS)
# Windows to never border (quickshell overlays, rofi, etc.)
IGNORE_CLASSES = {'quickshell', 'Rofi', 'rofi'}
IGNORE_TITLES = {'qs-focus-border', 'qs-focus-dim'}
# When any of these overlays are mapped, suppress the border entirely —
# focus may still report the underlying window during the brief window
# between binding event and overlay grabbing focus, leaving a frame
# visible around whatever was focused before mod+d / mod+p / mod+tab.
SUPPRESS_WHEN_PRESENT_TITLES = {'qs-launcher', 'qs-projects', 'qs-switcher', 'qs-clip', 'qs-notif'}
# i3 modes whose overlay covers the screen. That overlay
# (quickshell/qs-region.py) is a GDK POPUP window — override-redirect — so
# i3 emits NO window::new for it; a hide keyed off that event (the old
# contract here) would never fire.
#
# "screenshot" itself is deliberately NOT in this set any more: entering it
# now COLOURS the ring instead of hiding it (see COLOR_MODES) — a highlight
# of the window `w` would capture, matching the crosshair overlay's own
# accent colour. Suppression is deferred to the SYNTHETIC "screenshot-drag"
# mode, entered by qs-region.py itself (subprocess i3-msg call, its own
# `_press`) the moment the user actually starts drawing a region — the
# highlight is stale from then on, the user is selecting an arbitrary area,
# not capturing the ex-highlighted window. Same synthetic-mode-as-signal
# trick as nav's nav-move/nav-resize (dotfiles-5u6m): i3 itself binds
# nothing under "screenshot-drag" (the overlay's own grab already owns all
# input by the time it fires), it exists purely for this file and
# ModeBarTheme.resolve() to react to.
#
# Hide immediately at MODE ENTER (see the "change in SUPPRESS_MODES" branch
# in handle_event below); refreshes stay blocked for the whole mode so the
# border can't restack above the live overlay, and it reappears once the
# mode ends — cancel and save both funnel through the same i3
# "mode default" transition (fired by qs-screenshot.sh after the overlay
# exits, regardless of which path it exited through), so both are covered
# by the same code path.
SUPPRESS_MODES = {'screenshot-drag'}


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
        cr.set_source_rgb(*(MODE_BC if mode_colored else BC))
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

# The ring goes red from TWO independent sources now, and they must not clobber
# each other: an i3 mode in COLOR_MODES (screenshot), and a non-default hotkeyd
# layer (nav — no longer an i3 mode at all). Keeping one flag per source means a
# "mode default" event on leaving screenshot cannot blank a red that the layer
# feed owns, and vice versa. `mode_colored` is the derived OR, read by
# Border._draw. All three are main-thread-only, same discipline as
# mode_suppressed.
i3_mode_colored = False
layer_colored = False
mode_colored = False


def _recompute_colored():
    """Fold the two colour sources into mode_colored. True if it changed."""
    global mode_colored
    want = i3_mode_colored or layer_colored
    if want == mode_colored:
        return False
    mode_colored = want
    return True


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
    # mode started must not restack the border. It was already hidden at
    # mode-enter (see handle_event's mode branch) — just bail.
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
    # container/current/binding. Entering a SUPPRESS_MODES mode hides the
    # border immediately AND arms suppression (see SUPPRESS_MODES comment —
    # the overlay is an override-redirect POPUP, so a hide keyed off its
    # window::new would never fire). Any other mode, including "default",
    # unsuppresses and refreshes: leaving the screenshot mode must redraw
    # because the overlay never emits a focus event, and modes like "resize"
    # keep the live-refresh behavior.
    if 'container' not in e and 'current' not in e and 'binding' not in e:
        global mode_suppressed, i3_mode_colored
        # Recolour BEFORE any redraw below, so the refresh that follows a mode
        # change paints the new colour rather than the previous one. Only the
        # i3 half of the colour state is touched — a hotkeyd layer that is up at
        # the same time keeps the ring red through this event.
        i3_mode_colored = change in COLOR_MODES
        recolored = _recompute_colored()
        if change in SUPPRESS_MODES:
            border.hide()
            mode_suppressed = True
        else:
            mode_suppressed = False
            refresh_focused()
            # A mode swap that changes only the colour (screenshot -> default
            # with focus unchanged) still needs the ring repainted:
            # refresh_focused skips the GTK draw when geometry is identical.
            if recolored:
                border.win.queue_draw()
        return
    c = e.get('container')
    if not c:
        return
    if change == 'new':
        # A quickshell-hosted window mapped — the qs-launcher/qs-switcher/
        # qs-projects overlays, or a plain bar restart (PanelWindow with no
        # title reports the default name "quickshell"). It may cover the
        # screen and the border would float above it — hide now, before the
        # follow-up refresh restores it. NOT used for the screenshot
        # selector (quickshell/qs-region.py): that overlay hides on i3 MODE
        # ENTER (see the mode branch above), not here — it is a GDK POPUP
        # (override-redirect), and i3 never emits window::new for
        # override-redirect windows, so this branch would never see it.
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


def hotkeyd_layer_monitor():
    """Colour the ring from hotkeyd's layer feed (sp020 T7, dotfiles-hwds.9).

    The red "keys are captured" ring used to key off i3 mode events, which
    stopped existing for nav when the layer moved to the daemon. The daemon
    publishes {"layer": ..., "mod": ...} on a per-display unix socket and
    replays current state on connect, so a helper that starts late still paints
    correctly.

    [[adr0014]] shape: a failed connect or a closed socket ends the attempt and
    the retry is a fixed sleep OUTSIDE the read loop, so a missing daemon costs
    one connect per second rather than a spin.
    """
    import socket                                        # noqa: PLC0415

    display = os.environ.get('DISPLAY', ':0')
    tag = display.lstrip(':').split('.')[0]
    runtime = os.environ.get('XDG_RUNTIME_DIR') or f'/run/user/{os.getuid()}'
    path = f'{runtime}/hotkeyd-{tag}.sock'

    while True:
        try:
            c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            c.connect(path)
        except OSError:
            time.sleep(1)
            continue
        buf = b''
        try:
            while True:
                chunk = c.recv(4096)
                if not chunk:
                    break
                buf += chunk
                while b'\n' in buf:
                    line, buf = buf.split(b'\n', 1)
                    if not line.strip():
                        continue
                    try:
                        layer = json.loads(line).get('layer') or 'default'
                    except Exception:
                        continue
                    GLib.idle_add(_set_layer_colored, layer_colours_ring(layer))
        except OSError:
            pass
        finally:
            c.close()
        # The daemon went away or the socket broke: fall back to the plain
        # colour rather than leaving the ring red for a layer nobody is in.
        GLib.idle_add(_set_layer_colored, False)
        time.sleep(1)


def _set_layer_colored(colored):
    """Main-thread-only, same discipline as the mode flags."""
    global layer_colored
    layer_colored = colored
    if _recompute_colored():
        refresh_focused()
        border.win.queue_draw()
    return False


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
t_layer = threading.Thread(target=hotkeyd_layer_monitor, daemon=True)
t_layer.start()
t = threading.Thread(target=subscribe, daemon=True)
t.start()
t_mouse = threading.Thread(target=mouse_monitor, daemon=True)
t_mouse.start()
Gtk.main()
