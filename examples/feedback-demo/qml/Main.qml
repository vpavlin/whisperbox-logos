import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
// The host requires these imports for custom colours to apply.
import Logos.Theme
import Logos.Controls
// The form, exported from the WhisperBox studio (Export) and wrapped as a JS file so the view can
// import it from its own folder: var file = <the exported JSON>. It holds only the creator-signed
// form (public anyway, no keys).
import "FeedbackForm.js" as Form

// An app that wants feedback ships a WhisperBox form and asks Basecamp to show it (ADR 0023):
//   logos.request("whisperbox.respond", { form: <file text> }, function (r) { ... })
// WhisperBox checks the creator's signature, shows the form, seals the answer to the creator and
// sends it. The reply comes when the person sends (data.submitted = true) or leaves (false). If
// WhisperBox isn't installed, Basecamp offers to install it.
Item {
    id: root
    anchors.fill: parent
    property string status: ""

    function sendFeedback() {
        if (typeof logos === "undefined" || typeof logos.request !== "function") { root.status = "This Basecamp can't open other apps (no logos.request)."; return; }
        root.status = "Opening WhisperBox...";
        logos.request("whisperbox.respond", { form: JSON.stringify(Form.file) }, function (r) {
            if (!r || !r.ok) { root.status = "Couldn't open the form: " + (r && r.error ? r.error : "no answer"); return; }
            root.status = r.data && r.data.submitted ? "Thanks - your feedback was sealed and sent." : "No feedback sent.";
        });
    }

    Rectangle { anchors.fill: parent; color: "#0e0e14" }
    ColumnLayout {
        anchors.centerIn: parent
        width: Math.min(parent.width - 48, 520)
        spacing: 16
        Text { text: "Feedback demo"; color: "#f2f2f7"; font.pixelSize: 24; font.weight: Font.DemiBold }
        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: "#a8a8b8"; font.pixelSize: 14
               text: "This app ships the form “" + (Form.file.title || "") + "”. The button asks Basecamp to open it in WhisperBox; your answer is sealed so only the form's creator can read it." }
        Rectangle {
            implicitWidth: btnT.implicitWidth + 40; implicitHeight: 44; radius: 10; color: ma.containsMouse ? "#8d7ff8" : "#7c6cf6"
            Text { id: btnT; anchors.centerIn: parent; text: "Send feedback"; color: "white"; font.pixelSize: 15; font.weight: Font.DemiBold }
            MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.sendFeedback() }
        }
        Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; visible: text.length > 0; text: root.status; color: "#7fd8a4"; font.pixelSize: 13 }
    }
}
