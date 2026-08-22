import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Logos.Theme
import Logos.Controls

Item {
    id: root
    anchors.fill: parent

    readonly property color wbPrimary: "#7c6ff7"
    readonly property color wbPrimaryHover: "#9187f9"
    readonly property color wbPrimarySubtle: "#1e1b3a"
    readonly property color wbAccent: "#f7a44c"
    readonly property color wbBg: "#0b0b10"
    readonly property color wbSurface: "#14141e"
    readonly property color wbSurfaceRaised: "#1c1c2a"
    readonly property color wbBorder: "#2a2a3e"
    readonly property color wbBorderSubtle: "#1e1e30"
    readonly property color wbText: "#f0f0f8"
    readonly property color wbTextSec: "#a0a0b8"
    readonly property color wbTextTert: "#6b6b82"
    readonly property color wbSuccess: "#4ade80"
    readonly property color wbWarning: "#fbbf24"
    readonly property color wbError: "#f87171"

    property var st: ({})
    property string selectedId: ""
    property string toastMsg: ""
    property bool showCreate: false
    property bool showShare: false
    property var draftQuestions: []
    property var answers: ({})

    function callCore(m, a) {
        if (typeof logos === "undefined" || !logos.callModule) return "";
        return String(logos.callModule("whisperbox_core", m, a || []));
    }
    function asState(raw) {
        var s = String(raw || "").trim();
        for (var i = 0; i < 2 && s.charAt(0) === "\""; i++) { try { s = String(JSON.parse(s)).trim(); } catch (e) { return null; } }
        if (s.charAt(0) !== "{") return null;
        var o; try { o = JSON.parse(s); } catch (e) { return null; }
        return (o && o.error === undefined) ? o : null;
    }
    function apply(o) { if (!o) return; root.st = o; }
    function refresh() { apply(asState(callCore("snapshot", []))); }
    function mutate(m, a) { var r = asState(callCore(m, a)); if (r) { apply(r); return r; } return null; }
    function shortAddr(a) { if (!a) return "-"; return a.length > 14 ? a.substr(0, 6) + "…" + a.substr(-4) : a; }
    function toast(msg) { root.toastMsg = String(msg); toastTimer.restart(); }
    function addDraftQuestion() { root.draftQuestions = root.draftQuestions.concat([{ type: "text", text: "", required: true, optionsText: "" }]); }
    function removeDraftQuestion(idx) { var arr = root.draftQuestions.slice(); arr.splice(idx, 1); root.draftQuestions = arr; }
    function setDraftQuestion(idx, prop, value) { var arr = root.draftQuestions.slice(); var q = Object.assign({}, arr[idx]); q[prop] = value; arr[idx] = q; root.draftQuestions = arr; }
    function doCreate() {
        if (createTitle.text.trim().length === 0) { root.toast("Form needs a title"); return; }
        var def = { title: createTitle.text.trim(), description: "", questions: [] };
        for (var i = 0; i < draftQuestions.length; i++) {
            var q = draftQuestions[i];
            if (!q.text || !String(q.text).trim()) continue;
            def.questions.push({ id: "question_" + (i+1), type: "text", text: String(q.text).trim(), required: !!q.required });
        }
        if (def.questions.length === 0) { root.toast("Add at least one question"); return; }
        var r = mutate("createForm", [JSON.stringify(def)]);
        if (r && r.ok) {
            root.showCreate = false; createTitle.text = ""; root.draftQuestions = [];
            root.selectedId = String(r.formId || "").toLowerCase();
            root.toast("Form created");
        } else root.toast(r && r.error ? r.error : "Could not create form");
    }
    function doSubmit() {
        if (!root.selectedForm) return;
        var payload = { formId: root.selectedId, answers: root.answers };
        var r = mutate("submitResponse", [JSON.stringify(payload)]);
        if (r && r.ok) { root.toast("Response submitted"); root.answers = ({}); }
        else root.toast(r && r.error ? r.error : "Could not submit");
    }
    function shareUri() {
        if (!root.selectedForm) return "";
        var payload = JSON.stringify({ id: root.selectedForm.id, title: root.selectedForm.title || "" });
        return "whisperbox://form?" + encodeURIComponent(payload);
    }
    function copyShare() {
        root.toast("URI: " + root.shareUri().substr(0, 40) + "…");
    }
    function exportCsv() {
        root.toast("CSV export coming soon");
    }
    function setAnswer(qid, text) {
        var a = Object.assign({}, root.answers);
        a[qid] = text;
        root.answers = a;
    }

    readonly property var formsObj: st.state && st.state.forms ? st.state.forms : ({})
    readonly property var feed: st.state && st.state.feed ? st.state.feed : []
    readonly property var creatorView: st.creatorView || null
    readonly property string myAddress: (st.identity && st.identity.address) ? st.identity.address : ""
    readonly property bool nodeReady: !!st.nodeReady
    readonly property var selectedForm: formsObj[selectedId] || null
    function isCreator(f) { return !!(creatorView && f && creatorView.forms.indexOf(f.id) >= 0); }
    function responsesFor(fid) {
        if (!creatorView || !creatorView.responses || !creatorView.responses[fid]) return [];
        return creatorView.responses[fid];
    }

    Timer { interval: 2500; running: true; repeat: true; onTriggered: root.refresh() }
    Timer { id: toastTimer; interval: 3500; onTriggered: root.toastMsg = "" }
    Component.onCompleted: root.refresh()
    Connections {
        target: (typeof logos !== "undefined") ? logos : null
        ignoreUnknownSignals: true
        function onModuleEventReceived(module, event, data) {
            if (module === "whisperbox_core") root.apply(asState(data));
        }
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ══ SIDEBAR ══
        Rectangle {
            Layout.preferredWidth: 320
            Layout.fillHeight: true
            color: root.wbBg
            border.color: root.wbBorderSubtle
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                RowLayout {
                    spacing: 8
                    Text { text: "🔒"; font.pixelSize: 20 }
                    ColumnLayout {
                        spacing: 0
                        Text { text: "WhisperBox"; font.pixelSize: 16; font.weight: Font.Bold; color: root.wbText }
                        Text { text: "encrypted forms"; font.pixelSize: 11; color: root.wbTextTert }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 40
                    radius: 12
                    color: root.wbPrimary
                    Text {
                        anchors.centerIn: parent
                        text: "+ New Form"
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        color: "white"
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.showCreate = true }
                }

                Text { text: "JOIN A FORM"; font.pixelSize: 10; font.weight: Font.DemiBold; color: root.wbTextTert }
                Rectangle {
                    Layout.fillWidth: true
                    height: 38
                    radius: 12
                    color: root.wbSurfaceRaised
                    border.color: root.wbBorder
                    border.width: 1
                    TextField {
                        id: joinField
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        color: root.wbText
                        placeholderTextColor: root.wbTextTert
                        font.pixelSize: 12
                        background: null
                        placeholderText: "whisperbox:// URI or id"
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    height: 32
                    radius: 12
                    color: String(joinField.text || "").trim().length > 0 ? root.wbSurfaceRaised : "transparent"
                    border.color: String(joinField.text || "").trim().length > 0 ? root.wbBorder : "transparent"
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "Join"
                        font.pixelSize: 12
                        font.weight: Font.DemiBold
                        color: String(joinField.text || "").trim().length > 0 ? root.wbText : root.wbTextTert
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        enabled: String(joinField.text || "").trim().length > 0
                        onClicked: {
                            var t = String(joinField.text || "").trim();
                            if (!t) return;
                            var r = (t.indexOf("whisperbox://") === 0) ? root.mutate("importForm", [t]) : root.mutate("joinForm", [t]);
                            if (r && r.ok) { root.selectedId = String(r.formId || t).toLowerCase(); joinField.text = ""; root.toast("Watching form"); }
                            else root.toast(r && r.error ? r.error : "Could not join form");
                        }
                    }
                }

                Text { text: "FORMS"; font.pixelSize: 10; font.weight: Font.DemiBold; color: root.wbTextTert }

                ListView {
                    id: formListView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.feed
                    spacing: 6
                    delegate: Rectangle {
                        width: formListView.width
                        height: 56
                        radius: 12
                        color: modelData === root.selectedId ? root.wbPrimarySubtle : "transparent"
                        border.color: modelData === root.selectedId ? root.wbPrimary : "transparent"
                        border.width: 1
                        property var f: root.formsObj[modelData]

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 12
                            spacing: 8

                            Rectangle {
                                width: 32; height: 32
                                radius: 8
                                color: root.wbPrimarySubtle
                                Text { anchors.centerIn: parent; text: "📋"; font.pixelSize: 14 }
                            }

                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 1
                                Text {
                                    text: (f && f.title) ? f.title : modelData
                                    font.pixelSize: 13
                                    font.weight: Font.DemiBold
                                    color: root.wbText
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                                Text {
                                    text: {
                                        var nq = (f && f.questions) ? f.questions.length : 0;
                                        var nr = root.responsesFor(modelData).length;
                                        return nq + "q" + (nr > 0 ? " · " + nr + " resp" : "");
                                    }
                                    font.pixelSize: 11
                                    color: root.wbTextTert
                                }
                            }

                            Rectangle {
                                visible: root.isCreator(f)
                                width: mineB.implicitWidth + 14
                                height: 20
                                radius: 10
                                color: root.wbPrimarySubtle
                                Text {
                                    id: mineB
                                    anchors.centerIn: parent
                                    text: "Mine"
                                    font.pixelSize: 10
                                    font.weight: Font.DemiBold
                                    color: root.wbPrimary
                                }
                            }
                        }

                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.selectedId = modelData; root.answers = ({}); } }
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: root.wbBorderSubtle }
                RowLayout {
                    spacing: 6
                    Rectangle { width: 7; height: 7; radius: 4; color: root.nodeReady ? root.wbSuccess : root.wbWarning }
                    Text { text: root.nodeReady ? "Synced" : "Connecting…"; font.pixelSize: 11; color: root.wbTextTert }
                    Text { text: "· " + root.shortAddr(root.myAddress); font.pixelSize: 11; color: root.wbTextTert }
                }
            }
        }

        // ══ MAIN PANE ══
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: root.wbSurface

            // Empty state
            ColumnLayout {
                visible: !root.selectedForm
                anchors.centerIn: parent
                spacing: 12
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Select a form"
                    font.pixelSize: 18
                    font.weight: Font.DemiBold
                    color: root.wbTextSec
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Choose a form from the sidebar, or create a new one."
                    font.pixelSize: 13
                    color: root.wbTextTert
                }
            }

            // Form detail (scrollable)
            Flickable {
                id: detailFlick
                visible: !!root.selectedForm
                anchors.fill: parent
                anchors.margins: 24
                contentWidth: width
                contentHeight: detailCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: detailCol
                    width: detailFlick.width
                    spacing: 16

                    // Header
                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            Layout.fillWidth: true
                            text: root.selectedForm ? root.selectedForm.title : ""
                            font.pixelSize: 22
                            font.weight: Font.Bold
                            color: root.wbText
                            wrapMode: Text.WordWrap
                        }
                        Rectangle {
                            visible: root.isCreator(root.selectedForm)
                            width: shareBtnT.implicitWidth + 20
                            height: 32
                            radius: 12
                            color: root.wbSurfaceRaised
                            border.color: root.wbBorder
                            border.width: 1
                            Text {
                                id: shareBtnT
                                anchors.centerIn: parent
                                text: "Share"
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                                color: root.wbText
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.showShare = true }
                        }
                    }

                    Text {
                        Layout.fillWidth: true
                        visible: !!(root.selectedForm && root.selectedForm.description)
                        text: root.selectedForm ? root.selectedForm.description : ""
                        font.pixelSize: 13
                        color: root.wbTextSec
                        wrapMode: Text.WordWrap
                    }

                    RowLayout {
                        spacing: 8
                        Rectangle {
                            visible: root.selectedForm && root.selectedForm.status === "open"
                            width: stB.implicitWidth + 14
                            height: 20
                            radius: 10
                            color: "#1a3d2a"
                            Text {
                                id: stB
                                anchors.centerIn: parent
                                text: "Open"
                                font.pixelSize: 10
                                font.weight: Font.DemiBold
                                color: root.wbSuccess
                            }
                        }
                        Text {
                            text: "by " + root.shortAddr(root.selectedForm ? root.selectedForm.creator : "")
                            font.pixelSize: 12
                            color: root.wbTextTert
                        }
                    }

                    // ── CREATOR VIEW ──
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 16
                        visible: root.isCreator(root.selectedForm)

                        // Stats
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12

                            Rectangle {
                                Layout.fillWidth: true
                                height: 72
                                radius: 12
                                color: root.wbSurfaceRaised
                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 2
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: String(root.responsesFor(root.selectedId).length)
                                        font.pixelSize: 28
                                        font.weight: Font.Bold
                                        color: root.wbPrimary
                                    }
                                    Text { Layout.alignment: Qt.AlignHCenter; text: "Responses"; font.pixelSize: 11; color: root.wbTextTert }
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true
                                height: 72
                                radius: 12
                                color: root.wbSurfaceRaised
                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 2
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: {
                                            var n = 0;
                                            var resps = root.responsesFor(root.selectedId);
                                            for (var i = 0; i < resps.length; i++) if (resps[i].confirmed) n++;
                                            return String(n);
                                        }
                                        font.pixelSize: 28
                                        font.weight: Font.Bold
                                        color: root.wbText
                                    }
                                    Text { Layout.alignment: Qt.AlignHCenter; text: "Confirmed"; font.pixelSize: 11; color: root.wbTextTert }
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true
                                height: 72
                                radius: 12
                                color: root.wbSurfaceRaised
                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 2
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: {
                                            var total = root.responsesFor(root.selectedId).length;
                                            if (total === 0) return "—";
                                            var und = (root.creatorView && root.creatorView.undecrypted) || 0;
                                            return Math.round((total - und) / total * 100) + "%";
                                        }
                                        font.pixelSize: 28
                                        font.weight: Font.Bold
                                        color: root.wbSuccess
                                    }
                                    Text { Layout.alignment: Qt.AlignHCenter; text: "Decrypted"; font.pixelSize: 11; color: root.wbTextTert }
                                }
                            }
                        }

                        // Share card
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: shareCardCol.implicitHeight + 32
                            radius: 12
                            color: root.wbSurfaceRaised
                            border.color: root.wbBorderSubtle
                            border.width: 1

                            ColumnLayout {
                                id: shareCardCol
                                anchors.fill: parent
                                anchors.margins: 16
                                spacing: 10

                                Text { text: "SHARE THIS FORM"; font.pixelSize: 10; font.weight: Font.DemiBold; color: root.wbTextTert }
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 36
                                    radius: 8
                                    color: root.wbBg
                                    border.color: root.wbBorder
                                    border.width: 1
                                    Text {
                                        anchors.fill: parent
                                        anchors.leftMargin: 10
                                        anchors.rightMargin: 10
                                        verticalAlignment: Text.AlignVCenter
                                        text: root.shareUri()
                                        font.pixelSize: 11
                                        font.family: "monospace"
                                        color: root.wbTextSec
                                        elide: Text.ElideRight
                                    }
                                }
                                RowLayout {
                                    spacing: 8
                                    Rectangle {
                                        width: copyT.implicitWidth + 16
                                        height: 28
                                        radius: 8
                                        color: root.wbPrimary
                                        Text {
                                            id: copyT
                                            anchors.centerIn: parent
                                            text: "Copy Link"
                                            font.pixelSize: 11
                                            font.weight: Font.DemiBold
                                            color: "white"
                                        }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.copyShare() }
                                    }
                                    Text { text: "Respondents scan or open link"; font.pixelSize: 11; color: root.wbTextTert }
                                }
                            }
                        }

                        // Responses list
                        Text {
                            text: "RESPONSES (" + root.responsesFor(root.selectedId).length + ")"
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            color: root.wbTextTert
                        }

                        Repeater {
                            model: root.responsesFor(root.selectedId).length
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: respCol.implicitHeight + 24
                                radius: 12
                                color: root.wbSurfaceRaised
                                border.color: root.wbBorderSubtle
                                border.width: 1

                                property var resp: root.responsesFor(root.selectedId)[index]

                                ColumnLayout {
                                    id: respCol
                                    anchors.fill: parent
                                    anchors.margins: 14
                                    spacing: 10

                                    // Response header
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text {
                                            text: root.shortAddr(resp.from || resp.address || "unknown")
                                            font.pixelSize: 11
                                            font.family: "monospace"
                                            color: root.wbTextSec
                                        }
                                        Item { Layout.fillWidth: true }
                                        Rectangle {
                                            visible: resp.decrypted && !resp.confirmed
                                            width: decB.implicitWidth + 12
                                            height: 18
                                            radius: 9
                                            color: "#1a3d2a"
                                            Text {
                                                id: decB
                                                anchors.centerIn: parent
                                                text: "Decrypted"
                                                font.pixelSize: 9
                                                font.weight: Font.DemiBold
                                                color: root.wbSuccess
                                            }
                                        }
                                        Rectangle {
                                            visible: resp.confirmed
                                            width: confB.implicitWidth + 12
                                            height: 18
                                            radius: 9
                                            color: "#1a3d2a"
                                            Text {
                                                id: confB
                                                anchors.centerIn: parent
                                                text: "✓ Confirmed"
                                                font.pixelSize: 9
                                                font.weight: Font.DemiBold
                                                color: root.wbSuccess
                                            }
                                        }
                                        Rectangle {
                                            visible: !resp.decrypted
                                            width: undB.implicitWidth + 12
                                            height: 18
                                            radius: 9
                                            color: "#2a2a1a"
                                            Text {
                                                id: undB
                                                anchors.centerIn: parent
                                                text: "Encrypted"
                                                font.pixelSize: 9
                                                font.weight: Font.DemiBold
                                                color: root.wbWarning
                                            }
                                        }
                                    }

                                    // Q&A rows
                                    Repeater {
                                        model: (resp.answers && resp.answers.length) ? resp.answers.length : 0
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 12
                                            property var ans: resp.answers[index]

                                            Text {
                                                text: (ans.question || ans.q || "Q" + (index+1))
                                                font.pixelSize: 12
                                                color: root.wbTextTert
                                                width: 140
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                text: (ans.answer || ans.a || "—")
                                                font.pixelSize: 13
                                                color: (ans.answer || ans.a) ? root.wbText : root.wbTextTert
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Export CSV
                        Rectangle {
                            width: csvT.implicitWidth + 20
                            height: 32
                            radius: 12
                            color: root.wbSurfaceRaised
                            border.color: root.wbBorder
                            border.width: 1
                            Text {
                                id: csvT
                                anchors.centerIn: parent
                                text: "Export CSV"
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                                color: root.wbText
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.exportCsv() }
                        }
                    }

                    // ── RESPONDENT VIEW ──
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        visible: !root.isCreator(root.selectedForm) && root.selectedForm && root.selectedForm.questions

                        Repeater {
                            model: root.selectedForm.questions.length
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 6
                                property var qdef: root.selectedForm.questions[index]

                                Text {
                                    Layout.fillWidth: true
                                    text: qdef ? qdef.text + (qdef.required ? " *" : "") : ""
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: 14
                                    font.weight: Font.DemiBold
                                    color: root.wbText
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 44
                                    radius: 12
                                    color: root.wbSurfaceRaised
                                    border.color: root.wbBorder
                                    border.width: 1
                                    TextField {
                                        anchors.fill: parent
                                        anchors.leftMargin: 14
                                        anchors.rightMargin: 14
                                        color: root.wbText
                                        placeholderTextColor: root.wbTextTert
                                        font.pixelSize: 13
                                        background: null
                                        placeholderText: "Your answer"
                                        text: (root.answers[qdef.id] || root.answers["question_" + (index+1)]) || ""
                                        onTextChanged: root.setAnswer(qdef.id || "question_" + (index+1), text)
                                    }
                                }
                            }
                        }

                        // Submit
                        Rectangle {
                            Layout.fillWidth: true
                            height: 48
                            radius: 12
                            color: root.wbAccent
                            visible: root.selectedForm && root.selectedForm.status === "open"
                            Text {
                                anchors.centerIn: parent
                                text: "Submit Response"
                                font.pixelSize: 15
                                font.weight: Font.Bold
                                color: "#0b0b10"
                            }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.doSubmit() }
                        }

                        // Privacy note
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: privT.implicitHeight + 24
                            radius: 12
                            color: "#1a2a1a"
                            border.color: "#2a4d3a"
                            border.width: 1
                            Text {
                                id: privT
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.leftMargin: 16
                                anchors.rightMargin: 16
                                anchors.topMargin: 12
                                anchors.bottomMargin: 12
                                text: "🔒 Your answers are sealed end-to-end. Only the form creator can read them. No servers, no tracking."
                                wrapMode: Text.WordWrap
                                font.pixelSize: 12
                                color: root.wbSuccess
                            }
                        }
                    }
                }
            }
        }
    }

    // ══ SHARE OVERLAY ══
    Rectangle {
        anchors.fill: parent
        visible: root.showShare
        color: "#cc0b0b10"
        z: 10

        Rectangle {
            width: Math.min(480, parent.width - 48)
            height: Math.min(parent.height - 48, 320)
            anchors.centerIn: parent
            radius: 16
            color: root.wbSurface
            border.color: root.wbBorder
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 24
                spacing: 16

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "Share Form"; font.pixelSize: 20; font.weight: Font.Bold; color: root.wbText }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "✕"; font.pixelSize: 14; color: root.wbTextTert
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.showShare = false }
                    }
                }

                Text { text: "SHARE THIS FORM"; font.pixelSize: 10; font.weight: Font.DemiBold; color: root.wbTextTert }
                Rectangle {
                    Layout.fillWidth: true
                    height: 44
                    radius: 10
                    color: root.wbBg
                    border.color: root.wbBorder
                    border.width: 1
                    Text {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        verticalAlignment: Text.AlignVCenter
                        text: root.shareUri()
                        font.pixelSize: 12
                        font.family: "monospace"
                        color: root.wbTextSec
                        elide: Text.ElideRight
                    }
                }

                Text {
                    Layout.fillWidth: true
                    text: "Anyone with this link can respond. Responses are encrypted end-to-end — only you can read them."
                    font.pixelSize: 12
                    color: root.wbTextTert
                    wrapMode: Text.WordWrap
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "Close"; font.pixelSize: 13; color: root.wbTextTert
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.showShare = false }
                    }
                    Rectangle {
                        width: 120
                        height: 40
                        radius: 12
                        color: root.wbPrimary
                        Text {
                            anchors.centerIn: parent
                            text: "Copy Link"
                            font.pixelSize: 13
                            font.weight: Font.Bold
                            color: "white"
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.copyShare(); root.showShare = false; } }
                    }
                }
            }
        }
    }

    // ══ CREATE OVERLAY ══
    Rectangle {
        anchors.fill: parent
        visible: root.showCreate
        color: "#cc0b0b10"
        z: 10

        Rectangle {
            width: Math.min(560, parent.width - 48)
            height: Math.min(parent.height - 48, 450)
            anchors.centerIn: parent
            radius: 16
            color: root.wbSurface
            border.color: root.wbBorder
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 20
                spacing: 12

                RowLayout {
                    Layout.fillWidth: true
                    Text { text: "New Form"; font.pixelSize: 22; font.weight: Font.Bold; color: root.wbText }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "✕"; font.pixelSize: 14; color: root.wbTextTert
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.showCreate = false }
                    }
                }

                Text { text: "TITLE"; font.pixelSize: 10; font.weight: Font.DemiBold; color: root.wbTextTert }
                Rectangle {
                    Layout.fillWidth: true
                    height: 44
                    radius: 12
                    color: root.wbSurfaceRaised
                    border.color: root.wbBorder
                    border.width: 1
                    TextField {
                        id: createTitle
                        anchors.fill: parent
                        anchors.leftMargin: 14
                        anchors.rightMargin: 14
                        color: root.wbText
                        placeholderTextColor: root.wbTextTert
                        font.pixelSize: 14
                        font.weight: Font.DemiBold
                        background: null
                        placeholderText: "Form title"
                    }
                }

                Text { text: "QUESTIONS (" + root.draftQuestions.length + ")"; font.pixelSize: 10; font.weight: Font.DemiBold; color: root.wbTextTert }

                Repeater {
                    model: root.draftQuestions.length
                    Rectangle {
                        Layout.fillWidth: true
                        height: 44
                        radius: 8
                        color: root.wbSurfaceRaised
                        border.color: root.wbBorder
                        border.width: 1
                        RowLayout {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            spacing: 8
                            Text { text: "Q" + (index + 1); font.pixelSize: 12; font.weight: Font.DemiBold; color: root.wbPrimary }
                            TextField {
                                Layout.fillWidth: true
                                color: root.wbText
                                placeholderTextColor: root.wbTextTert
                                font.pixelSize: 13
                                background: null
                                placeholderText: "Question text"
                                text: String(root.draftQuestions[index].text || "")
                                onTextChanged: root.setDraftQuestion(index, "text", text)
                            }
                            Text {
                                text: "✕"; font.pixelSize: 12; color: root.wbTextTert
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.removeDraftQuestion(index) }
                            }
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 38
                    radius: 12
                    color: "transparent"
                    border.color: root.wbBorder
                    border.width: 1
                    Text {
                        anchors.centerIn: parent
                        text: "+ Add question"
                        font.pixelSize: 13
                        color: root.wbTextTert
                    }
                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.addDraftQuestion() }
                }

                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: 8
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "Cancel"; font.pixelSize: 14; color: root.wbTextTert
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.showCreate = false }
                    }
                    Rectangle {
                        width: 140
                        height: 44
                        radius: 12
                        color: root.wbPrimary
                        Text {
                            anchors.centerIn: parent
                            text: "Create & Share"
                            font.pixelSize: 14
                            font.weight: Font.Bold
                            color: "white"
                        }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.doCreate() }
                    }
                }
            }
        }
    }

    // ══ TOAST ══
    Rectangle {
        visible: !!root.toastMsg
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 24
        width: Math.min(440, root.width - 32)
        implicitHeight: toastT.implicitHeight + 24
        radius: 16
        color: root.wbSurfaceRaised
        border.color: root.wbBorder
        border.width: 1
        z: 20
        Text {
            id: toastT
            anchors.centerIn: parent
            width: parent.width - 32
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.toastMsg
            font.pixelSize: 13
            color: root.wbText
        }
    }
}
