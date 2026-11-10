// InputBox.qml - shared by the WhisperBox studio and the respond module (keep both copies identical:
// scripts/sync-respond.sh copies, the view test checks).
import QtQuick
import "WbPalette.js" as P

Rectangle {
    property bool invalid: false
    radius: 10
    color: P.wbSurfaceRaised
    border.color: invalid ? P.wbError : P.wbBorder
    border.width: 1
}
