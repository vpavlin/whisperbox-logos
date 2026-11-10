import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
// The host requires these imports for custom colours to apply.
import Logos.Theme
import Logos.Controls
import "WbPalette.js" as P

// WhisperBox Respond - answer ONE form, opened from a link (ADR 0021). Nothing to create or manage:
// that is the studio (the `whisperbox` module). Other apps open a form with the intent
//   whisperbox.respond { link: "whisperbox://form?id=...&by=..." }
// or the user pastes the link. The form itself is FormRespond.qml, the same component the studio
// uses, over the same core (whisperbox_core), so answers are identical whichever app sends them.
Item {
    id: root
    anchors.fill: parent

    property var st: ({})
    property string selectedId: ""
    property string toastMsg: ""
    property string pendingIntent: ""   // an intent's request id, answered once the form is open

    readonly property var forms: (st.state && st.state.forms) ? st.state.forms : ({})
    readonly property string myAddress: (st.identity && st.identity.address) ? st.identity.address : ""
    readonly property string coreStatus: st.status || (st.nodeReady ? "Connected" : "Connecting...")
    readonly property var sel: withDetail(forms[selectedId] || null)

    // ── core plumbing (async only: a blocking call would freeze the view) ──
    function callVia(m, a, cb) {
        var done = function (r) { try { cb(r === undefined || r === null ? "" : String(r)); } catch (e) { console.warn("whisperbox_respond callback", m, e); } };
        if (typeof logos === "undefined" || !logos) { Qt.callLater(function () { done(""); }); return; }
        if (typeof logos.callModuleAsync === "function") {
            try { logos.callModuleAsync("whisperbox_core", m, a || [], done, 20000); }
            catch (e) { Qt.callLater(function () { done(""); }); }
            return;
        }
        Qt.callLater(function () { var r = ""; try { r = logos.callModule("whisperbox_core", m, a || []); } catch (e) {} done(r); });
    }
    function parse(raw) {
        var s = String(raw || "").trim();
        for (var i = 0; i < 2 && s.charAt(0) === "\""; i++) { try { s = String(JSON.parse(s)).trim(); } catch (e) { return null; } }
        if (s.charAt(0) !== "{") return null;
        try { return JSON.parse(s); } catch (e) { return null; }
    }
    property bool refreshBusy: false
    property double refreshSince: 0
    function refresh() {
        if (root.refreshBusy && Date.now() - root.refreshSince < 45000) return;
        root.refreshBusy = true; root.refreshSince = Date.now();
        callVia("snapshot", [], function (raw) {
            var o = parse(raw);
            if (o && o.state) { root.st = o; Qt.callLater(root.loadDetail); }
            root.refreshBusy = false;
        });
    }
    property var inFlight: ({})
    function act(m, a, okMsg, cb) {
        if (root.inFlight[m]) return;
        var f = Object.assign({}, root.inFlight); f[m] = true; root.inFlight = f;
        callVia(m, a, function (raw) {
            var g = Object.assign({}, root.inFlight); delete g[m]; root.inFlight = g;
            var r = parse(raw);
            refresh();
            if (r && r.ok) { if (okMsg) toast(okMsg); if (cb) cb(r); return; }
            toast(r && r.error ? r.error : (raw === "" ? "WhisperBox didn't answer - is whisperbox_core installed?" : "Request failed"));
        });
    }
    function busy(m) { return !!root.inFlight[m]; }
    function toast(msg) { root.toastMsg = String(msg); toastTimer.restart(); }

    // The form's private parts come from formDetail, not the snapshot (open-review 2026-11-03, FR-2).
    property var detail: ({})
    property bool detailBusy: false
    function withDetail(f) {
        if (!f || root.detail.formId !== f.id) return f;
        var o = Object.assign({}, f), ks = ["myAnswers", "myReplies", "quiz", "answerDraft"];
        for (var i = 0; i < ks.length; i++) if (root.detail[ks[i]] !== undefined) o[ks[i]] = root.detail[ks[i]];
        return o;
    }
    function loadDetail() {
        var id = root.selectedId;
        if (!id || root.detailBusy) return;
        root.detailBusy = true;
        callVia("formDetail", [id], function (raw) {
            root.detailBusy = false;
            var r = parse(raw);
            if (!r || !r.ok || r.formId !== root.selectedId) return;
            var first = root.detail.formId !== r.formId;
            root.detail = r;
            if (first) respond.restoreAnswerDraft();
        });
    }

    // ── opening a form: a link (intent or pasted) -> the core adds it; the definition may still be syncing ──
    function openLink(link, requestId) {
        var t = String(link || "").trim();
        if (!t) { if (requestId) logos.respond(requestId, false, ({}), "no link"); return; }
        if (t.indexOf("whisperbox://") !== 0) {
            toast("That isn't a WhisperBox link (whisperbox://form?id=...)");
            if (requestId) logos.respond(requestId, false, ({}), "not a whisperbox:// link");
            return;
        }
        act("importForm", [t], "", function (r) {
            var id = String(r.formId || "").toLowerCase();
            respond.flushDraft();
            if (root.selectedId !== id) { root.detail = ({}); respond.reset(); }
            root.selectedId = id;
            linkField.text = "";
            if (r.pending) toast("Form found - waiting for it to arrive from its creator");
            Qt.callLater(root.loadDetail);
            if (requestId) logos.respond(requestId, true, ({ formId: id }), "");
        });
    }
    Connections {
        target: (typeof logos !== "undefined") ? logos : null
        ignoreUnknownSignals: true
        // Basecamp intents (stock 0.3.2): another app asks us to open a form
        function onIntentRequested(requestId, intent, params, requesterName) {
            if (intent !== "whisperbox.respond") return;
            root.openLink(params && params.link ? String(params.link) : "", requestId);
        }
        function onModuleEventReceived(module, event, data) {
            if (module === "whisperbox_core" && event === "stateChanged") {
                var o = root.parse(data);
                if (o && o.state) { root.st = o; Qt.callLater(root.loadDetail); }
            }
        }
    }
    Timer { interval: 2500; running: true; repeat: true; onTriggered: root.refresh() }
    Timer { id: toastTimer; interval: 3500; onTriggered: root.toastMsg = "" }
    Component.onCompleted: root.refresh()

    Rectangle { anchors.fill: parent; color: P.wbBg }

    ScrollView {
        anchors.fill: parent
        contentWidth: availableWidth
        clip: true
        ColumnLayout {
            width: Math.min(parent.width - 40, 760)
            x: (parent.width - width) / 2
            spacing: 18
            Item { implicitHeight: 12 }

            RowLayout {
                Layout.fillWidth: true
                spacing: 10
                Text { text: "WhisperBox"; color: P.wbText; font.pixelSize: 18; font.weight: Font.DemiBold; textFormat: Text.PlainText }
                Text { text: "answer a form"; color: P.wbTextTert; font.pixelSize: 13; textFormat: Text.PlainText }
                Item { Layout.fillWidth: true }
                Text { text: root.coreStatus; color: root.coreStatus === "Connected" ? P.wbSuccess : P.wbTextTert; font.pixelSize: 11; textFormat: Text.PlainText }
            }

            // no form yet: paste a link
            ColumnLayout {
                Layout.fillWidth: true
                visible: !root.sel
                spacing: 10
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; color: P.wbTextSec; font.pixelSize: 14; textFormat: Text.PlainText
                       text: root.selectedId ? "Waiting for the form to arrive from its creator..." : "Paste the link to a form. Your answers are sealed: only the people who made the form can read them." }
                RowLayout {
                    Layout.fillWidth: true; spacing: 8
                    InputBox {
                        Layout.fillWidth: true; implicitHeight: 40
                        TextField { id: linkField; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: P.wbText; placeholderTextColor: P.wbTextTert
                                    font.pixelSize: 13; background: null; placeholderText: "whisperbox://form?id=..."; onAccepted: root.openLink(text, "") }
                    }
                    WbButton { label: root.busy("importForm") ? "Opening..." : "Open"; primary: true; active: linkField.text.trim().length > 0 && !root.busy("importForm")
                               onClicked: root.openLink(linkField.text, "") }
                }
            }

            // the form
            ColumnLayout {
                Layout.fillWidth: true
                visible: !!root.sel
                spacing: 8
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; text: root.sel ? root.sel.title : ""; color: P.wbText; font.pixelSize: 22; font.weight: Font.DemiBold; textFormat: Text.PlainText }
                Text { Layout.fillWidth: true; wrapMode: Text.WordWrap; visible: !!(root.sel && root.sel.description); text: root.sel && root.sel.description ? root.sel.description : ""
                       color: P.wbTextSec; font.pixelSize: 14; textFormat: Text.PlainText }
            }
            FormRespond {
                id: respond
                Layout.fillWidth: true
                visible: !!root.sel
                form: root.sel
                myAddress: root.myAddress
                host: root
            }
            Text { visible: !!root.sel; Layout.fillWidth: true; wrapMode: Text.WordWrap; color: P.wbTextTert; font.pixelSize: 11; textFormat: Text.PlainText
                   text: "To make your own forms, install the WhisperBox studio." }
            Item { implicitHeight: 24 }
        }
    }

    Rectangle {
        anchors.bottom: parent.bottom; anchors.horizontalCenter: parent.horizontalCenter; anchors.bottomMargin: 24
        visible: root.toastMsg !== ""; radius: 10; color: P.wbSurfaceRaised; border.color: P.wbBorder
        width: Math.min(parent.width - 40, tt.implicitWidth + 32); height: tt.implicitHeight + 20
        Text { id: tt; anchors.centerIn: parent; width: Math.min(root.width - 72, implicitWidth); wrapMode: Text.WordWrap; text: root.toastMsg; color: P.wbText; font.pixelSize: 13; textFormat: Text.PlainText }
    }
}
