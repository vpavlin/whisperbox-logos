// LockIcon.qml - shared by the WhisperBox studio and the respond module (keep both copies identical:
// scripts/sync-respond.sh copies, the view test checks).
import QtQuick
import "WbPalette.js" as P

Item {
    property color tint: P.wbPrimary
    implicitWidth: 16; implicitHeight: 19
    Rectangle { x: 3; y: 0; width: 10; height: 12; radius: 5; color: "transparent"; border.color: parent.tint; border.width: 2 }
    Rectangle { x: 0; y: 7; width: 16; height: 12; radius: 3; color: parent.tint }
    Rectangle { x: 7; y: 11; width: 2; height: 4; radius: 1; color: P.wbBg }
}
