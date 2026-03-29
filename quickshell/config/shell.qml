import Quickshell
import Quickshell.Io

ShellRoot {
    property int globalNotifCount: 0

    IpcHandler {
        target: "notif"
        function setCount(count: string): void {
            globalNotifCount = parseInt(count) || 0
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
}
