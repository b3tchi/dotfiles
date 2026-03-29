import Quickshell
import Quickshell.Services.Notifications

ShellRoot {
    property int globalNotifCount: notifSrv.trackedNotifications.values.length
    property string lastNotifText: ""

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
        }
    }

    Variants {
        model: Quickshell.screens
        Bar {
            required property var modelData
            screen: modelData
            notifCount: globalNotifCount
            notifText: lastNotifText
        }
    }
}
