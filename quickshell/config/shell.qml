import QtQuick
import Quickshell
import "./Common"

ShellRoot {
    // Over RDP (QS_RDP=1): single quickshell process — focus border/dim off
    // (X11 compositing overlays, glitchy without a compositor), and the
    // launcher/switcher/projects overlay is hosted in THIS instance instead of
    // a second `quickshell -p overlay` process.
    // Per-session knobs (flags, bar geometry, density) live in Common/Session.qml.
    readonly property bool isRdp: Session.isRdp
    readonly property bool focusFx: !isRdp

    // Notifications (sp019): this instance is now a READ-ONLY consumer.
    // The single NotificationServer lives in the dedicated
    // `quickshell -p notif` daemon (quickshell/notif/shell.qml, Task 2),
    // launched user-wide behind a flock (qs-start.sh, Task 3) so exactly one
    // process ever owns org.freedesktop.Notifications regardless of how
    // many sessions (local + xrdp, adr0004) are live. Every bar (Bar.qml,
    // Task 4) tails the daemon's live-state file directly — no server, no
    // notif-state properties, and no signal wiring back to this host remain
    // here at all.

    Loader { active: focusFx; sourceComponent: Component { FocusBorder {} } }
    Loader { active: focusFx; sourceComponent: Component { FocusDim {} } }

    // RDP single-instance: host the launcher/switcher/projects overlay here.
    Loader { active: isRdp; sourceComponent: Component { Overlay {} } }

    // Clipboard-history picker (sp014). Hosted in the MAIN instance on every
    // session type — desktop and RDP alike — so `qs-clip.sh toggle` finds
    // exactly one picker per session and rapid reopening cannot orphan a
    // window. Idle until its IPC target is called.
    ClipHistory {}

    Variants {
        model: Quickshell.screens
        Bar {
            required property var modelData
            screen: modelData
        }
    }

    // Bottom rounded-corner clearance (phone/Razr xrdp only). Reserves the
    // bottom inset as strut so apps stay clear of the physical corners while
    // the bar sits at the top. Hidden (no strut) on desktop-shaped screens.
    Variants {
        model: Quickshell.screens
        BarChin {
            required property var modelData
            screen: modelData
        }
    }
}
