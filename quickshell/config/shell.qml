import Quickshell
import Quickshell.Services.Notifications
import QtQuick

ShellRoot {
    property int globalNotifCount: notifSrv.trackedNotifications.values.length

    NotificationServer {
        id: notifSrv
        keepOnReload: true
        bodyMarkupSupported: true
        imageSupported: false
        actionsSupported: false
        persistenceSupported: false

        onNotification: notification => {
            notification.tracked = true
        }
    }

    Variants {
        model: Quickshell.screens
        Bar {
            required property var modelData
            screen: modelData
            notifCount: globalNotifCount
        }
    }

    // NotificationPopup disabled — X11 proot rendering crashes with second window
    // TODO: re-enable on Wayland or after quickshell X11 fix
    //NotificationPopup {
    //    server: notifSrv
    //}
}
