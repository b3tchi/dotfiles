import QtQuick
import Quickshell
import Quickshell.Services.Notifications
import "./Common"

ShellRoot {
    // Over RDP (QS_RDP=1): single quickshell process — focus border/dim off
    // (X11 compositing overlays, glitchy without a compositor), and the
    // launcher/switcher/projects overlay is hosted in THIS instance instead of
    // a second `quickshell -p overlay` process.
    // Per-session knobs (flags, bar geometry, density) live in Common/Session.qml.
    readonly property bool isRdp: Session.isRdp
    readonly property bool focusFx: !isRdp

    property int globalNotifCount: 0
    property string lastNotifText: ""
    property int globalNotifSeq: 0
    property bool globalHasCritical: {
        var vals = notifSrv.trackedNotifications.values
        for (var i = 0; i < vals.length; i++) {
            if (vals[i].urgency === NotificationUrgency.Critical) return true
        }
        return false
    }

    function relativeTime(ms) {
        var s = Math.floor((Date.now() - ms) / 1000)
        if (s < 60) return "-" + s + "s"
        var m = Math.floor(s / 60)
        if (m < 60) return "-" + m + "m"
        var d = new Date(ms)
        return ("0" + d.getHours()).slice(-2) + ":" + ("0" + d.getMinutes()).slice(-2)
    }

    function dismissLatest() {
        var vals = notifSrv.trackedNotifications.values
        if (vals.length > 0) {
            var n = vals[vals.length - 1]
            var text = (n.summary ?? "").replace(/\n/g, " ")
            var body = (n.body ?? "").replace(/\n/g, " ").replace(/<[^>]*>/g, "")
            if (body !== "") text += " — " + body
            if (n._arrivalTime !== undefined) text = relativeTime(n._arrivalTime) + "  " + text
            lastNotifText = text
            globalNotifSeq++
            if (globalNotifCount > 0) globalNotifCount--
            n.dismiss()
        }
    }

    property var _currentNotif: null

    function trackCurrent() {
        if (_currentNotif) {
            globalNotifCount++
            _currentNotif = null
        }
    }

    function dismissCurrentSilent() {
        if (_currentNotif) {
            _currentNotif.dismiss()
            _currentNotif = null
        }
    }

    function dismissLatestSilent() {
        dismissCurrentSilent()
    }

    NotificationServer {
        id: notifSrv
        keepOnReload: true
        bodyMarkupSupported: true
        imageSupported: false
        actionsSupported: false
        persistenceSupported: false

        onNotification: notification => {
            trackCurrent()
            notification.tracked = true
            notification._arrivalTime = Date.now()
            _currentNotif = notification
            var text = (notification.summary ?? "").replace(/\n/g, " ")
            var body = (notification.body ?? "").replace(/\n/g, " ").replace(/<[^>]*>/g, "")
            if (body !== "") text += " — " + body
            lastNotifText = text
            globalNotifSeq++
        }
    }

    Loader { active: focusFx; sourceComponent: Component { FocusBorder {} } }
    Loader { active: focusFx; sourceComponent: Component { FocusDim {} } }

    // RDP single-instance: host the launcher/switcher/projects overlay here.
    Loader { active: isRdp; sourceComponent: Component { Overlay {} } }

    Variants {
        model: Quickshell.screens
        Bar {
            required property var modelData
            screen: modelData
            notifCount: globalNotifCount
            notifText: lastNotifText
            notifSeq: globalNotifSeq
            hasCritical: globalHasCritical
            onDismissNotif: dismissLatest()
            onDismissNotifSilent: dismissLatestSilent()
            onTickerFinished: trackCurrent()
        }
    }
}
