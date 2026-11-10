// WbButton.qml - shared by the WhisperBox studio and the respond module (keep both copies identical:
// scripts/sync-respond.sh copies, the view test checks).
import QtQuick
import "WbPalette.js" as P

Rectangle {
    id: btn
    property string label: ""
    property bool primary: false
    property bool danger: false
    property bool active: true
    signal clicked()
    implicitWidth: btnT.implicitWidth + 28
    implicitHeight: 36
    radius: 10
    opacity: active ? 1 : 0.45
    color: primary ? (btnMa.containsMouse && active ? "#9187f9" : P.wbPrimary) : (btnMa.containsMouse && active ? P.wbBorder : P.wbSurfaceRaised)
    border.color: primary ? "transparent" : (danger ? P.wbError : P.wbBorder)
    border.width: 1
    Text { textFormat: Text.PlainText;
        id: btnT
        anchors.centerIn: parent
        text: btn.label
        font.pixelSize: 12
        font.weight: Font.DemiBold
        color: btn.primary ? "white" : (btn.danger ? P.wbError : P.wbText)
    }
    MouseArea { id: btnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: btn.active ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: if (btn.active) btn.clicked() }
}
