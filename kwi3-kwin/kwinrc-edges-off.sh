#!/bin/sh
# kwinrc-edges-off.sh - turn off KWin's hot corners and screen-edge actions for
# the kwi3-kwin session. Idempotent. deploy-kwin-host.sh runs it, and it can be
# run alone: the running KWin picks the change up without a logout.
#
# i3kwin owns the screen and hotkeyd owns the keys, so nothing here should fire
# from the pointer resting in a corner. KWin's defaults do: overview and
# windowview stay loaded and reserve their borders from compiled-in defaults,
# which is why a kwinrc with no such keys still has live corners.
set -eu

# ElectricNone in KWin's ElectricBorder enum. An empty value is not the same: it
# can fall back to the default. 9 is what the Screen Edges KCM writes for "none".
NONE=9

off() {   # off GROUP KEY...
    _group=$1
    shift
    for _key in "$@"; do
        kwriteconfig6 --file kwinrc --group "$_group" --key "$_key" "$NONE"
    done
}

off Effect-overview \
    BorderActivate TouchBorderActivate \
    GridBorderActivate GridTouchBorderActivate
off Effect-windowview \
    BorderActivate BorderActivateAll \
    BorderActivateClass BorderActivateClassCurrentDesktop \
    TouchBorderActivate TouchBorderActivateAll \
    TouchBorderActivateClass TouchBorderActivateClassCurrentDesktop

# Dragging a window into a corner or edge quick-tiles or maximizes it, on top of
# i3kwin's own layout.
kwriteconfig6 --file kwinrc --group Windows --key ElectricBorderMaximize false
kwriteconfig6 --file kwinrc --group Windows --key ElectricBorderTiling false

# Same as kwi3's test rig (i3kwin/test/kwin-rig/session.sh): name every border
# None, and do not load the effects that reserve borders at all. The border keys
# above alone left the corners live. screenedge only draws the glow at a reserved
# edge, so it has nothing to do here either.
for _border in Top TopRight Right BottomRight Bottom BottomLeft Left TopLeft; do
    kwriteconfig6 --file kwinrc --group ElectricBorders --key "$_border" None
done
for _effect in overview windowview desktopgrid screenedge; do
    kwriteconfig6 --file kwinrc --group Plugins --key "${_effect}Enabled" false
    # reconfigure keeps an already-loaded effect running, so unload it by hand.
    gdbus call --session --dest org.kde.KWin --object-path /Effects \
        --method org.kde.kwin.Effects.unloadEffect "$_effect" >/dev/null 2>&1 || true
done

# No session bus or no KWin (a deploy from a tty): the next KWin start reads it.
gdbus call --session --dest org.kde.KWin --object-path /KWin \
    --method org.kde.KWin.reconfigure >/dev/null 2>&1 || true

echo "kwinrc: KWin screen edges and corners off"
