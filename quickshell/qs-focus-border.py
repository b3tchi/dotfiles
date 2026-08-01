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
# NO i3-MODE COLOUR SET LIVES HERE ANY MORE (sp024, dotfiles-0tv1.2), just as
# no i3-mode SUPPRESSION set has since sp023. There used to be a COLOR_MODES
# containing 'screenshot' — the aiming phase of a capture, which i3 owned as a
# real mode. It is a hotkeyd EXTERNAL LAYER now (see hotkeyd_layer_monitor
# below), so the general layer rule already colours it and a dedicated i3 set
# would be the same signal on a second channel.
#
# `nav` had left the same way one cutover earlier (sp020 T7). Nothing i3 emits
# colours the frame today: the feed is the SOLE source, and `layer_colored` is
# the only flag Border._draw reads.

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

# ...and the SUPPRESSING ones (sp023, dotfiles-1m4t.6). These do not merely go
# uncoloured — the border is HIDDEN outright and every refresh is blocked for
# as long as the layer is up.
#
# "screenshot-drag" is a hotkeyd EXTERNAL layer: it holds no grabs and binds no
# keys, it exists purely as a signal. quickshell/qs-region.py raises it
# (`hotkeyd set-layer screenshot-drag`) from its own `_press` the moment the
# user starts drawing a region, and quickshell/qs-screenshot.sh clears it on
# every exit path — capture, cancel, or crash — because qs-region.py can be
# killed outright mid-drag and the launcher is what outlives it.
#
# WHY THE BORDER MUST GO, not just recolour: the ring is a keep-above
# NOTIFICATION window, so every refresh restacks it — and during a drag
# refreshes fire constantly (binding events, the 100ms mouse poll). It would
# restack above the live selector overlay and be baked into the capture. The
# aiming-phase highlight (the "screenshot" LAYER, which this one supersedes at
# mouse-press time) is also stale from this point on: the user is selecting an
# arbitrary area, not capturing the window that was highlighted.
#
# WHY THIS IS A LAYER AND NOT AN i3 MODE any more: it used to travel as a
# synthetic `i3-msg mode screenshot-drag` against a real `mode
# "screenshot-drag" {}` block, purely because i3's mode-change IPC was the only
# channel already wired to both qs-region.py and this file. hotkeyd's state
# socket is that channel now, so sp023 retired the i3 mode and the signal rides
# the feed instead — one state-feed pattern instead of two. The daemon replays
# current state on connect, so a helper (re)started mid-drag starts suppressed
# rather than flashing a frame into the capture.
#
# BOTH CUES ARE THE FEED'S, EXCLUSIVELY. No i3 mode arms or disarms suppression
# (sp023) and none colours the ring either (sp024) — the aiming phase that used
# to be the last i3 mode in the gesture is now the "screenshot" LAYER, so both
# phases arrive in order on ONE channel and the whole clobber class (an i3
# "mode default" un-hiding the border while the overlay is still up) is gone
# rather than defended against.
SUPPRESS_LAYERS = {'screenshot-drag'}


def layer_colours_ring(layer):
    """Should the daemon's current layer paint the ring in MODE_BC?"""
    return (HOTKEYD_COLORS_ANY_LAYER
            and layer != 'default'
            and layer not in SILENT_LAYERS
            # Suppression WINS over colour: there is no ring to paint while the
            # border is hidden, and a red flag left standing here would survive
            # into the redraw that follows the layer clearing.
            and layer not in SUPPRESS_LAYERS)
# Windows to never border (quickshell overlays, rofi, etc.)
IGNORE_CLASSES = {'quickshell', 'Rofi', 'rofi'}
IGNORE_TITLES = {'qs-focus-border', 'qs-focus-dim'}
# When any of these overlays are mapped, suppress the border entirely —
# focus may still report the underlying window during the brief window
# between binding event and overlay grabbing focus, leaving a frame
# visible around whatever was focused before mod+d / mod+p / mod+tab.
SUPPRESS_WHEN_PRESENT_TITLES = {'qs-launcher', 'qs-projects', 'qs-switcher', 'qs-clip', 'qs-notif'}
# NO i3-MODE SUPPRESSION SET LIVES HERE ANY MORE (sp023, dotfiles-1m4t.6), and
# since sp024 (dotfiles-0tv1.2) no i3-mode COLOUR set either — see MODE_BC.
# The screenshot selector (quickshell/qs-region.py) is a GDK POPUP window —
# override-redirect — so i3 emits NO window::new for it and a hide keyed off
# that event would never fire. That hide is real and still required; it just
# hangs off the daemon's layer feed now instead of an i3 mode. See
# SUPPRESS_LAYERS above and _set_layer_state below.


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
        cr.set_source_rgb(*(MODE_BC if layer_colored else BC))
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

# While a SUPPRESS_LAYERS layer is up the border (keep-above notification)
# would restack above the overlay dock on every refresh — binding events and
# the 100ms mouse-drag poll fire constantly during a selection drag. Block
# all refreshes until the layer clears. Only touched on the GLib main thread:
# the layer feed's reader thread hands the name over via GLib.idle_add, and
# every other event/poll path already runs there.
#
# Name kept as `mode_suppressed` although the trigger is now a LAYER — it is
# read in apply_geom and refresh_focused, and the flag means the same thing it
# always did ("something is covering the screen; do not draw").
mode_suppressed = False

# The ring goes red from ONE source: a non-default, non-silent, non-suppressed
# hotkeyd layer. Read directly by Border._draw. Main-thread-only, same
# discipline as mode_suppressed.
#
# There were THREE flags here until sp024 (dotfiles-0tv1.2): `i3_mode_colored`
# for the i3 half (COLOR_MODES), `layer_colored` for the feed half, and a
# derived `mode_colored` OR-fold recomputed by `_recompute_colored`. The fold
# existed purely so an i3 "mode default" event on leaving the aiming phase
# could not blank a red the layer feed owned, and vice versa. The aiming phase
# is a LAYER now, so there is no second source to fold, and the whole clobber
# class it defended against cannot arise — see MODE_BC.
layer_colored = False


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
    # suppress layer came up must not restack the border. It was already hidden
    # when the layer arrived (see _set_layer_state) — just bail. The flag keeps
    # its historical name; the trigger has been a LAYER since sp023.
    if mode_suppressed:
        return
    if should_ignore(c):
        border.hide()
        return
    r = c.get('rect', {})
    deco_h = c.get('deco_rect', {}).get('height', 0)
    # WHERE the title bar sits relative to `rect` is not constant, so deco_h
    # alone cannot say whether to extend upward. i3 answers it in
    # `window_rect.y` — the client area's offset INSIDE `rect` (dotfiles-5wod):
    #
    #   window_rect.y == 0       Title drawn ABOVE `rect`. The strip belongs to
    #                            the parent (a tabbed container's tab bar), so
    #                            `rect` is the client only and must grow upward.
    #   window_rect.y == deco_h  Title already INSIDE `rect` — a leaf in a plain
    #                            split, where `rect` spans title + client. The
    #                            frame IS `rect`; extending overshoots by deco_h
    #                            and the ring floats above the window.
    #
    # The second shape was unhandled until dotfiles-5wod, so every window NOT in
    # a tabbed container got a ring 24px too high and 24px too tall.
    #
    # The tabbed check below stays for a third shape window_rect.y cannot name:
    # a leaf inside a splith/splitv that is itself inside tabbed/stacked. i3
    # reports deco_h=24 for that leaf even though no per-leaf title is rendered
    # (the tab strip belongs to the splith intermediate, not this leaf).
    in_tabbed = any(p.get('layout') in ('tabbed', 'stacked') for p in parents)
    direct_in_tabbed = parents and parents[-1].get('layout') in ('tabbed', 'stacked')
    if c.get('window_rect', {}).get('y', 0) > 0:
        deco_h = 0
    elif in_tabbed and not direct_in_tabbed:
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
    # THERE IS NO i3 "mode" BRANCH ANY MORE (sp024, dotfiles-0tv1.2), and
    # "mode" is off the subscribe list below, so one should not even arrive.
    #
    # It used to set the i3 half of the colour state (COLOR_MODES) and refresh.
    # Both halves moved: the colour comes off the layer feed, and the refresh +
    # queue_draw that went with it are carried by _set_layer_state, which does
    # exactly the same pair whenever the colour flips or a suppression lifts.
    # quickshell/test_qs_focus_border_mode.py pins that (aiming-enter and
    # aiming-clear both assert refresh AND queue_draw) rather than assuming it.
    #
    # A mode-shaped event can still reach here on a half-updated estate — an i3
    # that has not reloaded since the mode blocks were deleted from
    # i3/config.common. It has only 'change', so it falls straight through the
    # container check below and is FULLY INERT: no colour, no suppression, no
    # refresh. That is the point. A second channel that still moved the border
    # would be the double-fire class the migration exists to kill.
    #
    # What that costs: under the panic config (hotkeyd stopped,
    # zz-fallback-binds.conf linked in) i3's real nav/resize/$mode_system modes
    # no longer drive a refresh each. Accepted — COLOR_MODES never held those
    # names, so no colour is lost, and window/binding events still refresh.
    c = e.get('container')
    if not c:
        return
    if change == 'new':
        # A quickshell-hosted window mapped — the qs-launcher/qs-switcher/
        # qs-projects overlays, or a plain bar restart (PanelWindow with no
        # title reports the default name "quickshell"). It may cover the
        # screen and the border would float above it — hide now, before the
        # follow-up refresh restores it. NOT used for the screenshot
        # selector (quickshell/qs-region.py): that overlay hides when the
        # "screenshot-drag" LAYER arrives (see _set_layer_state), not here —
        # it is a GDK POPUP (override-redirect), and i3 never emits
        # window::new for override-redirect windows, so this branch would
        # never see it.
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
    """Drive the ring from hotkeyd's layer feed (sp020 T7, dotfiles-hwds.9).

    The red "keys are captured" ring used to key off i3 mode events, which
    stopped existing for nav when the layer moved to the daemon. The daemon
    publishes {"layer": ..., "mod": ...} on a per-display unix socket and
    replays current state on connect, so a helper that starts late still paints
    correctly.

    Since sp024 (dotfiles-0tv1.2) this feed is the ONLY input either cue has:
    the last i3 colouring mode, the screenshot AIMING phase, became the
    "screenshot" layer, so both phases of a capture now arrive here in order
    (screenshot -> screenshot-drag -> default) on one channel.

    Since sp023 (dotfiles-1m4t.6) this feed carries BOTH cues: the colour, and
    the SUPPRESSION that hides the border for the whole screenshot drag. The
    line's layer NAME is what goes to the main thread — the reader no longer
    decides anything itself, so a name can mean "colour" today and "hide" too
    without this loop changing. Replay-on-connect is what makes suppression
    safe to key off a feed at all: a helper (re)started mid-drag is told
    `screenshot-drag` as its FIRST line and starts hidden, instead of drawing a
    frame into the live capture before the next transition arrives.

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
                        # Malformed line: skip THIS line and keep reading. It
                        # must not disturb the current state — a garbage byte
                        # arriving mid-drag that reset suppression would
                        # un-hide the border into a live capture.
                        continue
                    GLib.idle_add(_set_layer_state, layer)
        except OSError:
            pass
        finally:
            c.close()
        # The daemon went away or the socket broke: fall back to the default
        # layer rather than leaving the ring red for a layer nobody is in —
        # and, since sp023, rather than leaving the border HIDDEN FOREVER for a
        # drag nobody is in. The feed that would have cleared the suppression
        # is the thing that just died, so this fallback is the only path left
        # that can bring the border back.
        GLib.idle_add(_set_layer_state, 'default')
        time.sleep(1)


def _set_layer_state(layer):
    """Apply one layer NAME from the feed. Main-thread-only, same discipline
    as mode_suppressed (the reader thread reaches it via GLib.idle_add).

    Both cues the feed carries are decided here, in this order: suppression
    first, because a suppress layer must never also colour (layer_colours_ring
    already refuses to, and this is the second half of that contract).

    Since sp024 this is the ONLY thing that colours or refreshes off a phase
    change — the i3 mode branch that used to do it for the aiming phase is
    gone, and its refresh_focused() + queue_draw() pair is the one below.
    """
    global layer_colored, mode_suppressed
    suppress = layer in SUPPRESS_LAYERS
    # Recolour BEFORE any redraw below, so the refresh that follows paints the
    # new colour rather than the previous one.
    want_colored = layer_colours_ring(layer)
    recolored = want_colored != layer_colored
    layer_colored = want_colored
    if suppress:
        # Arm BEFORE hiding: a refresh already in flight re-checks the flag in
        # apply_geom, so arming first closes the window in which it could
        # restack the border above the overlay after the hide.
        mode_suppressed = True
        border.hide()
        return False
    was_suppressed = mode_suppressed
    mode_suppressed = False
    # Leaving a suppress layer redraws even when nothing about the COLOUR
    # changed: the border is hidden at that point and only a refresh brings it
    # back.
    #
    # The explicit queue_draw is NOT redundant with refresh_focused, because
    # refresh_focused may decline to repaint at all: it returns immediately
    # while mode_suppressed is set, and its worker bails on _refresh_lock
    # contention or hides the border outright when _has_overlay_present. The
    # synchronous draw is what guarantees the colour flip lands in those cases.
    #
    # An earlier version of this comment claimed refresh_focused "skips the GTK
    # draw when geometry is identical". No such short-circuit exists — apply_geom
    # calls border.update() unconditionally, and update() ends in its own
    # queue_draw. Corrected at dotfiles-0tv1.4, which also made the test
    # assertions here discriminate (they previously passed with this line
    # deleted, because update()'s draw masked its absence).
    if recolored or was_suppressed:
        refresh_focused()
        border.win.queue_draw()
    return False


def subscribe():
    """Subscribe to i3 window/workspace/binding events; reconnects on failure."""
    while True:
        try:
            proc = subprocess.Popen(
                # "mode" left this list with the mode branch (sp024): nothing
                # in this file reacts to an i3 mode any more, and subscribing
                # to an event with no handler is how a dead channel quietly
                # comes back to life.
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
    try:
        e = json.loads(data)
        # Binding events — refresh after any keybinding (catches move/resize/layout)
        #
        # There used to be a pre-arm branch here, sniffing the binding's COMMAND
        # for a suppress mode so suppression beat the mode event that followed
        # it. It went with the mode (sp023, dotfiles-1m4t.6): the ordering
        # hazard it guarded does not exist on the layer feed, which publishes
        # the state itself rather than being inferred from a bind's side
        # effects. Keeping it would be worse than dead code — it armed a flag
        # only an i3 mode event could clear, and no i3 mode event clears
        # suppression any more, so a stale bind would hide the border for good.
        # The refresh below is a no-op while a suppress layer is up.
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
t_layer = threading.Thread(target=hotkeyd_layer_monitor, daemon=True)
t_layer.start()
t = threading.Thread(target=subscribe, daemon=True)
t.start()
t_mouse = threading.Thread(target=mouse_monitor, daemon=True)
t_mouse.start()
Gtk.main()
