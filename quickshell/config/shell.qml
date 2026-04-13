import Quickshell
import Quickshell.Services.Notifications

ShellRoot {
    property int globalNotifCount: notifSrv.trackedNotifications.values.length
    property string lastNotifText: ""
    property int globalNotifSeq: 0
    property bool globalHasCritical: {
        var vals = notifSrv.trackedNotifications.values
        for (var i = 0; i < vals.length; i++) {
            if (vals[i].urgency === NotificationUrgency.Critical) return true
        }
        return false
    }

    function dismissLatest() {
        var vals = notifSrv.trackedNotifications.values
        if (vals.length > 0) {
            var n = vals[vals.length - 1]
            var text = n.summary ?? ""
            if ((n.body ?? "") !== "") text += " — " + n.body
            lastNotifText = text
            globalNotifSeq++
            n.dismiss()
        }
    }

    NotificationServer {
        id: notifSrv
        keepOnReload: true
        bodyMarkupSupported: true
        imageSupported: false
        actionsSupported: false
        persistenceSupported: false

        onNotification: notification => {
            notification.tracked = true
            var text = notification.summary ?? ""
            if ((notification.body ?? "") !== "") text += " — " + notification.body
            lastNotifText = text
            globalNotifSeq++
        }
    }

    FocusBorder {}

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
        }
    }
}
