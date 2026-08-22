import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

// WhisperBox v0.2 — privacy-first encrypted forms over Waku.
// Desktop layout: sidebar (320px) + main pane. Matches approved web mockup v2.
// All logic in whisperbox_core. This view polls snapshot() and renders JSON.
//
// QML constraints (learned the hard way):
//   - NO typed handler params (onActivated: function(int x) → silent compile fail)
//   - Use untyped handlers + currentIndex
//   - LogosText + LogosButton only as Logos* types
//   - Append-only member order in C++ (mutex layout)
//   - No Clipboard type — TextEdit hack

Item {
    id: root
    anchors.fill: parent

    // ── DESIGN TOKENS (from approved mockup v2) ───────────────────────────────
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
    readonly property int wbR1: 8
    readonly property int wbR2: 12
    readonly property int wbR3: 16
    readonly property int wbR4: 24
    readonly property int wbS1: 4
    readonly property int wbS2: 8
    readonly property int wbS3: 12
    readonly property int wbS4: 16
    readonly property int wbS5: 24
    readonly property int wbS6: 32

    // ── STATE PLUMBING ────────────────────────────────────────────────────────
    property string stateJson: "{}"
    property var st: ({})

    function callCore(m, a) {
        if (typeof logos === "undefined" || !logos.callModule) return "";
        return String(logos.callModule("whisperbox_core", m, a || []));
    }
    function asState(raw) {
        var s = String(raw || "").trim();
        for (var i = 0; i < 2 && s.charAt(0) === '"'; i++) { try { s = String(JSON.parse(s)).trim(); } catch (e) { return null; } }
        if (s.charAt(0) !== "{") return null;
        var o; try { o = JSON.parse(s); } catch (e) { return null; }
        return (o && o.error === undefined) ? o : null;
    }
    function formCountOf(o) {
        if (!o || !o.state || !o.state.forms) return 0;
        return Object.keys(o.state.forms).length;
    }
    function apply(o) {
        if (!o) return;
        if (formCountOf(o) === 0 && formCountOf(root.st) > 0) return;
        root.st = o; root.stateJson = JSON.stringify(o);
        root.autoSelect();
    }
    function autoSelect() {
        if (root.selectedId && root.formsObj[root.selectedId]) return;
        if (root.feed.length > 0) root.selectedId = String(root.feed[0]).toLowerCase();
    }
    function refresh() { apply(asState(callCore("snapshot", []))); }
    function mutate(m, a) {
        var r = asState(callCore(m, a));
        if (r) { apply(r); return r; }
        return null;
    }

    Timer { interval: 2500; running: true; repeat: true;
             onTriggered: {
                 root.refresh();
                 if (root.selectedForm && root.isCreator(root.selectedForm) && !root.shareUriText)
                     Qt.callLater(root.buildShare);
             } }
    Component.onCompleted: {
        if (typeof logos !== "undefined" && logos.onModuleEvent) logos.onModuleEvent("whisperbox_core", "stateChanged");
        root.refresh();
    }
    Connections {
        target: (typeof logos !== "undefined") ? logos : null
        ignoreUnknownSignals: true
        function onModuleEventReceived(module, event, data) {
            if (module === "whisperbox_core") root.apply(asState(data));
        }
    }

    // ── DERIVED STATE ─────────────────────────────────────────────────────────
    readonly property var formsObj: st.state && st.state.forms ? st.state.forms : ({})
    readonly property var feed: st.state && st.state.feed ? st.state.feed : []
    readonly property var creatorView: st.creatorView || null
    readonly property string myAddress: (st.identity && st.identity.address) ? st.identity.address : ""
    readonly property bool nodeReady: !!st.nodeReady
    readonly property var diag: st.diagnostics || ({})
    readonly property var mySubsArr: st.mySubmissions || []

    property string selectedId: ""
    readonly property var selectedForm: formsObj[selectedId] || null

    function isCreator(f) { return !!(creatorView && f && creatorView.forms.indexOf(f.id) >= 0); }
    function responsesFor(fid) {
        if (!creatorView || !creatorView.responses || !creatorView.responses[fid]) return [];
        return creatorView.responses[fid];
    }
    function hasResponded(fid) { return mySubsArr.indexOf(fid) >= 0; }
    function shortAddr(a) {
        if (!a) return "-";
        return a.length > 14 ? a.substr(0, 6) + "…" + a.substr(-4) : a;
    }
    function fmtTime(ms) {
        if (!ms) return "-";
        try { return new Date(Number(ms)).toLocaleString(); } catch (e) { return String(ms); }
    }
    readonly property var formList: {
        var ids = [];
        for (var i = 0; i < feed.length; i++) ids.push(feed[i]);
        var keys = Object.keys(root.formsObj);
        for (var k = 0; k < keys.length; k++) if (ids.indexOf(keys[k]) < 0) ids.push(keys[k]);
        return ids;
    }

    // toast
    property string toastMsg: ""
    function toast(msg) { root.toastMsg = String(msg); toastTimer.restart(); }
    Timer { id: toastTimer; interval: 3500; onTriggered: root.toastMsg = "" }

    // ── CREATE FORM DRAFT ─────────────────────────────────────────────────────
    property bool showCreate: false
    property var draftQuestions: []
    function addDraftQuestion() {
        root.draftQuestions = root.draftQuestions.concat([{ type: "text", text: "", required: true, optionsText: "" }]);
    }
    function removeDraftQuestion(idx) {
        var arr = root.draftQuestions.slice(); arr.splice(idx, 1); root.draftQuestions = arr;
    }
    function normType(q) {
        if (!q) return "text";
        var t = q.type;
        if (t === "textarea" || t === "radioButtons" || t === "checkbox") return t;
        if (typeof t === "number") {
            var m = ["text", "textarea", "radioButtons", "checkbox"];
            if (t >= 0 && t < 4) return m[t];
        }
        return "text";
    }
    function answerWidget(q) {
        var t = normType(q);
        if ((t === "radioButtons" || t === "checkbox") && (!q.options || q.options.length < 2)) return "text";
        return t;
    }
    function setDraftQuestion(idx, prop, value) {
        var arr = root.draftQuestions.slice();
        var q = Object.assign({}, arr[idx]);
        q[prop] = value;
        arr[idx] = q;
        root.draftQuestions = arr;
    }
    function doCreate() {
        if (createTitle.text.trim().length === 0) { root.toast("Form needs a title"); return; }
        var def = { title: createTitle.text.trim(), description: createDesc.text.trim(), questions: [] };
        for (var i = 0; i < draftQuestions.length; i++) {
            var q = draftQuestions[i];
            if (!q.text || !String(q.text).trim()) continue;
            var oq = { id: "question_" + (i + 1), type: q.type, text: String(q.text).trim(), required: !!q.required };
            if (q.type === "radioButtons" || q.type === "checkbox") {
                var opts = String(q.optionsText || "").split("\n").map(function (s) { return s.trim(); })
                    .filter(function (s) { return s.length > 0; });
                if (opts.length < 2) { root.toast("Choice questions need at least 2 options"); return; }
                oq.options = opts;
            }
            def.questions.push(oq);
        }
        if (def.questions.length === 0) { root.toast("Add at least one question"); return; }
        var r = mutate("createForm", [JSON.stringify(def)]);
        if (r && r.ok) {
            root.selectedId = String(r.formId).toLowerCase();
            root.showCreate = false;
            createTitle.text = ""; createDesc.text = ""; root.draftQuestions = [];
            root.toast("Form created");
        } else root.toast(r && r.error ? r.error : "Could not create form");
    }

    // ── JOIN ──────────────────────────────────────────────────────────────────
    function doJoin() {
        var t = String(joinField.text || "").trim();
        if (!t) return;
        var r = (t.indexOf("whisperbox://") === 0) ? mutate("importForm", [t]) : mutate("joinForm", [t]);
        if (r && r.ok) {
            root.selectedId = String(r.formId || t).toLowerCase();
            joinField.text = "";
            root.toast("Watching form");
        } else root.toast(r && r.error ? r.error : "Could not join form");
    }

    // ── SHARE / QR ────────────────────────────────────────────────────────────
    property string shareUriText: ""
    property var qrData: null
    property bool showShare: false
    function buildShare() {
        if (!root.selectedForm) { root.shareUriText = ""; root.qrData = null; return; }
        if (!root.isCreator(root.selectedForm)) { root.shareUriText = ""; root.qrData = null; return; }
        var fid = root.selectedForm.id;
        try {
            var raw = callCore("shareUri", [fid]);
            var res = raw;
            for (var k = 0; k < 2 && typeof res === "string"; k++) { try { res = JSON.parse(res); } catch (e) { break; } }
            if (res && res.ok && res.uri) root.shareUriText = String(res.uri);
            else root.shareUriText = "";
        } catch (e) {}
        try {
            var q = callCore("shareQr", [fid]);
            for (var j = 0; j < 2 && typeof q === "string"; j++) { try { q = JSON.parse(q); } catch (e2) { break; } }
            if (q && q.ok && q.n && q.cells && q.cells.length >= q.n * q.n) {
                root.qrData = { n: q.n, cells: q.cells };
                try { qrCanvas.requestPaint(); } catch (e3) {}
            } else root.qrData = null;
        } catch (e) {}
    }
    onSelectedIdChanged: {
        root.draftAnswers = ({});
        root.showShare = false;
        if (root.selectedForm && root.isCreator(root.selectedForm)) Qt.callLater(root.buildShare);
        else { root.shareUriText = ""; root.qrData = null; }
    }

    // ── RESPONDENT ANSWER DRAFT ───────────────────────────────────────────────
    property var draftAnswers: ({})
    function setAnswer(qid, v) {
        var a = Object.assign({}, root.draftAnswers);
        a[qid] = v;
        root.draftAnswers = a;
    }
    function answerValue(qid) { return root.draftAnswers[qid]; }
    function doSubmit() {
        if (!root.selectedForm) return;
        var f = root.selectedForm;
        var arr = [];
        for (var i = 0; i < f.questions.length; i++) {
            var q = f.questions[i];
            var v = root.draftAnswers[q.id];
            if (v === undefined || v === null || v === "") {
                if (q.required) { root.toast("Required: " + q.text); return; }
                continue;
            }
            arr.push({ questionId: q.id, value: v });
        }
        var r = mutate("submitResponse", [f.id, JSON.stringify(arr)]);
        if (r && r.ok) root.toast("Response sent — sealed to the creator only");
        else root.toast(r && r.error ? r.error : "Could not submit response");
    }

    // ── CSV ───────────────────────────────────────────────────────────────────
    property bool showCsv: false
    property string csvText: ""
    function doExportCsv() {
        if (!root.selectedForm) return;
        var r = asState(callCore("exportCsv", [root.selectedForm.id]));
        if (r && r.ok && r.csv !== undefined) { root.csvText = String(r.csv); root.showCsv = true; }
        else root.toast(r && r.error ? r.error : "Export failed");
    }

    TextEdit { id: clip; visible: false }

    // ═══════════════════════════════════════════════════════════════════════════
    // LAYOUT — sidebar (320px) + main pane
    // ═══════════════════════════════════════════════════════════════════════════

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ══ SIDEBAR ══════════════════════════════════════════════════════════
        Rectangle {
            Layout.preferredWidth: 320
            Layout.fillHeight: true
            color: "#ff0000" // DEBUG: test if colors are applied
            border.color: root.wbBorderSubtle
            border.width: 1
            border.left: 0; border.top: 0; border.bottom: 0

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: root.wbS4
                spacing: root.wbS4

                // Brand
                RowLayout {
                    spacing: root.wbS2
                    Canvas {
                        width: 28; height: 28
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, 28, 28);
                            ctx.strokeStyle = root.wbPrimary;
                            ctx.lineWidth = 2;
                            ctx.lineCap = "round";
                            ctx.beginPath(); ctx.roundRect(3, 7, 22, 16, 4); ctx.stroke();
                            ctx.beginPath(); ctx.moveTo(7, 7); ctx.lineTo(7, 5);
                            ctx.quadraticCurveTo(7, 3, 9, 3); ctx.lineTo(19, 3);
                            ctx.quadraticCurveTo(21, 3, 21, 5); ctx.lineTo(21, 7); ctx.stroke();
                            ctx.beginPath(); ctx.moveTo(11, 12);
                            ctx.quadraticCurveTo(11, 10, 13, 10); ctx.lineTo(16, 10);
                            ctx.quadraticCurveTo(18, 10, 18, 12); ctx.lineTo(18, 14);
                            ctx.quadraticCurveTo(18, 16, 16, 16); ctx.lineTo(15, 16); ctx.stroke();
                        }
                    }
                    ColumnLayout {
                        spacing: 0
                        Text { text: "WhisperBox"; font.pixelSize: 16; font.weight: Font.Bold; color: root.wbText }
                        Text { text: "encrypted forms"; font.pixelSize: 11; color: root.wbTextTert }
                    }
                }

                // New Form button
                Rectangle {
                    Layout.fillWidth: true
                    height: 40
                    radius: root.wbR2
                    color: root.wbPrimary
                    Text {
                        anchors.centerIn: parent
                        text: "+ New Form"
                        font.pixelSize: 13
                        font.weight: Font.DemiBold
                        color: "white"
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.showCreate = true
                    }
                }

                // Join section
                Text {
                    text: "JOIN A FORM"
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    color: root.wbTextTert
                    letterSpacing: 0.5
                }
                Rectangle {
                    Layout.fillWidth: true
                    height: 38
                    radius: root.wbR2
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
                        selectByMouse: true
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    height: 32
                    radius: root.wbR2
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
                        onClicked: root.doJoin()
                    }
                }

                // Forms label
                Text {
                    text: "FORMS"
                    font.pixelSize: 10
                    font.weight: Font.DemiBold
                    color: root.wbTextTert
                    letterSpacing: 0.5
                }

                // Form list
                ListView {
                    id: formListView
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.formList
                    spacing: 6
                    delegate: Rectangle {
                        width: formListView.width
                        height: 56
                        radius: root.wbR2
                        color: modelData === root.selectedId ? root.wbPrimarySubtle : "transparent"
                        border.color: modelData === root.selectedId ? root.wbPrimary : "transparent"
                        border.width: 1

                        property var f: root.formsObj[modelData]

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: root.wbS3
                            spacing: root.wbS2

                            Rectangle {
                                width: 32; height: 32
                                radius: root.wbR1
                                color: root.wbPrimarySubtle
                                Text {
                                    anchors.centerIn: parent
                                    text: "📋"
                                    font.pixelSize: 14
                                }
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

                            // Badges
                            RowLayout {
                                spacing: 4
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
                                Rectangle {
                                    visible: root.hasResponded(modelData) && !root.isCreator(f)
                                    width: ansB.implicitWidth + 14
                                    height: 20
                                    radius: 10
                                    color: "#1a2a3d"
                                    Text {
                                        id: ansB
                                        anchors.centerIn: parent
                                        text: "✓"
                                        font.pixelSize: 10
                                        font.weight: Font.DemiBold
                                        color: "#60a5fa"
                                    }
                                }
                                Rectangle {
                                    visible: f && f.status === "closed"
                                    width: clB.implicitWidth + 14
                                    height: 20
                                    radius: 10
                                    color: "#1e1e30"
                                    Text {
                                        id: clB
                                        anchors.centerIn: parent
                                        text: "Closed"
                                        font.pixelSize: 10
                                        font.weight: Font.DemiBold
                                        color: root.wbTextTert
                                    }
                                }
                            }
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selectedId = modelData
                        }
                    }
                }

                // Footer: sync status
                Rectangle {
                    Layout.fillWidth: true
                    height: 1
                    color: root.wbBorderSubtle
                }
                RowLayout {
                    spacing: root.wbS2
                    Rectangle {
                        width: 7; height: 7; radius: 4
                        color: root.nodeReady ? root.wbSuccess : root.wbWarning
                    }
                    Text {
                        text: root.nodeReady ? "Synced" : "Connecting…"
                        font.pixelSize: 11
                        color: root.wbTextTert
                    }
                    Text {
                        text: "· " + root.shortAddr(root.myAddress)
                        font.pixelSize: 11
                        color: root.wbTextTert
                    }
                }
                Text {
                    text: "rx " + (root.diag.rxRaw || 0) + " / tx " + (root.diag.txTotal || 0)
                    font.pixelSize: 10
                    color: root.wbTextTert
                }
            }
        }

        // ══ MAIN PANE ═════════════════════════════════════════════════════════
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: root.wbSurface

            // Empty state
            ColumnLayout {
                visible: !root.selectedForm
                anchors.centerIn: parent
                spacing: root.wbS3
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

            // Form detail
            Flickable {
                visible: !!root.selectedForm
                anchors.fill: parent
                clip: true
                contentWidth: width
                contentHeight: detailCol.height + 2 * root.wbS6
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: detailCol
                    width: parent.width - 2 * root.wbS6
                    x: root.wbS6
                    y: root.wbS6
                    spacing: root.wbS5

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
                        // Actions (creator)
                        RowLayout {
                            visible: root.isCreator(root.selectedForm)
                            spacing: root.wbS2
                            Rectangle {
                                width: shareBtnT.implicitWidth + 20
                                height: 32
                                radius: root.wbR2
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
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: { root.buildShare(); root.showShare = true; }
                                }
                            }
                            Rectangle {
                                visible: !(root.selectedForm && root.selectedForm.status === "closed")
                                width: closeBtnT.implicitWidth + 20
                                height: 32
                                radius: root.wbR2
                                color: "#2a1a1a"
                                border.color: "#3d2020"
                                border.width: 1
                                Text {
                                    id: closeBtnT
                                    anchors.centerIn: parent
                                    text: "Close"
                                    font.pixelSize: 12
                                    font.weight: Font.DemiBold
                                    color: root.wbError
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: {
                                        var r = root.mutate("closeForm", [root.selectedId]);
                                        if (r && r.ok) root.toast("Form closed");
                                        else root.toast(r && r.error ? r.error : "Could not close form");
                                    }
                                }
                            }
                        }
                    }

                    // Description + meta
                    Text {
                        Layout.fillWidth: true
                        visible: !!(root.selectedForm && root.selectedForm.description)
                        text: root.selectedForm ? root.selectedForm.description : ""
                        font.pixelSize: 13
                        color: root.wbTextSec
                        wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        spacing: root.wbS2
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

                    // ══ CREATOR SECTION ═══════════════════════════════════════
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: root.wbS4
                        visible: root.isCreator(root.selectedForm)

                        // Stats row
                        RowLayout {
                            Layout.fillWidth: true
                            spacing: root.wbS3
                            Rectangle {
                                Layout.fillWidth: true
                                height: 72
                                radius: root.wbR2
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
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: "Responses"
                                        font.pixelSize: 11
                                        color: root.wbTextTert
                                    }
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true
                                height: 72
                                radius: root.wbR2
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
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: "Confirmed"
                                        font.pixelSize: 11
                                        color: root.wbTextTert
                                    }
                                }
                            }
                            Rectangle {
                                Layout.fillWidth: true
                                height: 72
                                radius: root.wbR2
                                color: root.wbSurfaceRaised
                                ColumnLayout {
                                    anchors.centerIn: parent
                                    spacing: 2
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: {
                                            var total = root.responsesFor(root.selectedId).length;
                                            var und = (root.creatorView && root.creatorView.undecrypted) || 0;
                                            if (total === 0) return "—";
                                            return Math.round((total - und) / total * 100) + "%";
                                        }
                                        font.pixelSize: 28
                                        font.weight: Font.Bold
                                        color: root.wbSuccess
                                    }
                                    Text {
                                        Layout.alignment: Qt.AlignHCenter
                                        text: "Decrypted"
                                        font.pixelSize: 11
                                        color: root.wbTextTert
                                    }
                                }
                            }
                        }

                        // Share card
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: shareRow.implicitHeight + 2 * root.wbS5
                            radius: root.wbR3
                            color: root.wbSurfaceRaised
                            border.color: root.wbBorderSubtle
                            border.width: 1

                            RowLayout {
                                id: shareRow
                                anchors.centerIn: parent
                                width: parent.width - 2 * root.wbS5
                                spacing: root.wbS5

                                Canvas {
                                    id: qrCanvas
                                    width: 120; height: 120
                                    visible: !!root.qrData
                                    onPaint: {
                                        var ctx = getContext("2d");
                                        ctx.clearRect(0, 0, width, height);
                                        if (!root.qrData) return;
                                        var n = root.qrData.n, cells = root.qrData.cells;
                                        var s = Math.min(width, height) / n;
                                        ctx.fillStyle = "#ffffff";
                                        ctx.fillRect(0, 0, n * s, n * s);
                                        ctx.fillStyle = "#14141f";
                                        for (var i = 0; i < n * n; i++) {
                                            if (!cells[i]) continue;
                                            var x = i % n, y = Math.floor(i / n);
                                            ctx.fillRect(x * s, y * s, s + 0.5, s + 0.5);
                                        }
                                    }
                                }

                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: root.wbS2
                                    Text {
                                        text: "SHARE THIS FORM"
                                        font.pixelSize: 10
                                        font.weight: Font.DemiBold
                                        color: root.wbTextTert
                                        letterSpacing: 0.5
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        implicitHeight: uriT.implicitHeight + 2 * root.wbS2
                                        radius: root.wbR1
                                        color: root.wbSurface
                                        border.color: root.wbBorder
                                        border.width: 1
                                        Text {
                                            id: uriT
                                            anchors.left: parent.left
                                            anchors.right: parent.right
                                            anchors.top: parent.top
                                            anchors.bottom: parent.bottom
                                            anchors.leftMargin: root.wbS2
                                            anchors.rightMargin: root.wbS2
                                            anchors.topMargin: root.wbS2
                                            anchors.bottomMargin: root.wbS2
                                            text: root.shareUriText || "(building…)"
                                            font.pixelSize: 11
                                            font.family: "monospace"
                                            color: root.wbTextSec
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                            elide: Text.ElideRight
                                        }
                                    }
                                    RowLayout {
                                        spacing: root.wbS2
                                        Rectangle {
                                            width: copyBtnT.implicitWidth + 20
                                            height: 30
                                            radius: root.wbR2
                                            color: root.wbPrimary
                                            Text {
                                                id: copyBtnT
                                                anchors.centerIn: parent
                                                text: "Copy Link"
                                                font.pixelSize: 12
                                                font.weight: Font.DemiBold
                                                color: "white"
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: { clip.text = root.shareUriText; clip.select(); clip.copy(); root.toast("Link copied"); }
                                            }
                                        }
                                        Text {
                                            text: "Respondents scan or open link"
                                            font.pixelSize: 11
                                            color: root.wbTextTert
                                        }
                                    }
                                }
                            }
                        }

                        // Responses
                        Text {
                            text: "RESPONSES (" + root.responsesFor(root.selectedId).length + ")"
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            color: root.wbTextTert
                            letterSpacing: 0.5
                        }

                        Repeater {
                            model: root.responsesFor(root.selectedId)
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: respCol.implicitHeight + 2 * root.wbS4
                                radius: root.wbR2
                                color: root.wbSurfaceRaised
                                border.color: root.wbBorderSubtle
                                border.width: 1
                                property var resp: modelData

                                ColumnLayout {
                                    id: respCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.margins: root.wbS4
                                    spacing: root.wbS3

                                    RowLayout {
                                        spacing: root.wbS2
                                        Text {
                                            text: root.shortAddr(resp.respondent)
                                            font.pixelSize: 11
                                            font.family: "monospace"
                                            color: root.wbTextSec
                                        }
                                        Text {
                                            text: root.fmtTime(resp.submittedAt)
                                            font.pixelSize: 11
                                            color: root.wbTextTert
                                        }
                                        Item { Layout.fillWidth: true }
                                        Rectangle {
                                            visible: resp.confirmed !== true
                                            width: confBtnT.implicitWidth + 18
                                            height: 26
                                            radius: 13
                                            color: root.wbPrimarySubtle
                                            Text {
                                                id: confBtnT
                                                anchors.centerIn: parent
                                                text: "Confirm"
                                                font.pixelSize: 11
                                                font.weight: Font.DemiBold
                                                color: root.wbPrimary
                                            }
                                            MouseArea {
                                                anchors.fill: parent
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: root.mutate("confirmResponse", [root.selectedId, resp.respondent])
                                            }
                                        }
                                        Rectangle {
                                            visible: resp.confirmed === true
                                            width: confB.implicitWidth + 14
                                            height: 20
                                            radius: 10
                                            color: "#1a3d2a"
                                            Text {
                                                id: confB
                                                anchors.centerIn: parent
                                                text: "✓ Confirmed"
                                                font.pixelSize: 10
                                                font.weight: Font.DemiBold
                                                color: root.wbSuccess
                                            }
                                        }
                                    }

                                    Repeater {
                                        model: (resp.answers) ? resp.answers.length : 0
                                        RowLayout {
                                            spacing: root.wbS2
                                            Text {
                                                text: {
                                                    var q = null;
                                                    if (root.selectedForm && root.selectedForm.questions) {
                                                        for (var i = 0; i < root.selectedForm.questions.length; i++) {
                                                            if (root.selectedForm.questions[i].id === resp.answers[index].questionId) { q = root.selectedForm.questions[i]; break; }
                                                        }
                                                    }
                                                    return (q ? q.text : resp.answers[index].questionId);
                                                }
                                                font.pixelSize: 12
                                                color: root.wbTextTert
                                                width: 120
                                                elide: Text.ElideRight
                                            }
                                            Text {
                                                Layout.fillWidth: true
                                                wrapMode: Text.WordWrap
                                                text: {
                                                    var q = null;
                                                    if (root.selectedForm && root.selectedForm.questions) {
                                                        for (var i = 0; i < root.selectedForm.questions.length; i++) {
                                                            if (root.selectedForm.questions[i].id === resp.answers[index].questionId) { q = root.selectedForm.questions[i]; break; }
                                                        }
                                                    }
                                                    var v = resp.answers[index].value;
                                                    if (q && q.type === "radioButtons" && q.options) return q.options[v] !== undefined ? q.options[v] : String(v);
                                                    if (q && q.type === "checkbox" && q.options) {
                                                        var parts = [];
                                                        for (var j = 0; j < v.length; j++) parts.push(q.options[v[j]] !== undefined ? q.options[v[j]] : String(v[j]));
                                                        return parts.join(", ");
                                                    }
                                                    return String(v);
                                                }
                                                font.pixelSize: 13
                                                color: root.wbText
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // Export CSV
                        Rectangle {
                            width: csvBtnT.implicitWidth + 24
                            height: 34
                            radius: root.wbR2
                            color: root.wbSurfaceRaised
                            border.color: root.wbBorder
                            border.width: 1
                            Text {
                                id: csvBtnT
                                anchors.centerIn: parent
                                text: "Export CSV"
                                font.pixelSize: 12
                                font.weight: Font.DemiBold
                                color: root.wbText
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.doExportCsv()
                            }
                        }
                    }

                    // ══ RESPONDENT SECTION ════════════════════════════════════
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: root.wbS4
                        visible: !root.isCreator(root.selectedForm) && root.selectedForm && root.selectedForm.status === "open"

                        // Already responded
                        Rectangle {
                            Layout.fillWidth: true
                            visible: root.hasResponded(root.selectedId)
                            implicitHeight: alreadyT.implicitHeight + 2 * root.wbS3
                            radius: root.wbR2
                            color: "#1a3d2a"
                            border.color: "#2a4d3a"
                            border.width: 1
                            Text {
                                id: alreadyT
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.leftMargin: root.wbS4
                                anchors.rightMargin: root.wbS4
                                anchors.topMargin: root.wbS3
                                anchors.bottomMargin: root.wbS3
                                text: "✓ You already responded to this form. The creator will see your sealed answers."
                                wrapMode: Text.WordWrap
                                font.pixelSize: 13
                                color: root.wbSuccess
                            }
                        }

                        // Answer form
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: root.wbS5
                            visible: !root.hasResponded(root.selectedId)

                            Text {
                                Layout.fillWidth: true
                                visible: (root.selectedForm && root.selectedForm.questions) ? root.selectedForm.questions.length === 0 : false
                                text: "Waiting for form data — it arrives over the mesh shortly."
                                wrapMode: Text.WordWrap
                                font.pixelSize: 13
                                color: root.wbTextTert
                            }

                            Repeater {
                                model: (root.selectedForm && root.selectedForm.questions) ? root.selectedForm.questions.length : 0
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: root.wbS3
                                    property var qdef: (root.selectedForm && root.selectedForm.questions) ? root.selectedForm.questions[index] : null

                                    Text {
                                        Layout.fillWidth: true
                                        text: qdef ? qdef.text + (qdef.required ? " *" : "") : ""
                                        wrapMode: Text.WordWrap
                                        font.pixelSize: 14
                                        font.weight: Font.DemiBold
                                        color: root.wbText
                                    }

                                    // Text input
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 44
                                        radius: root.wbR2
                                        color: root.wbSurfaceRaised
                                        border.color: root.wbBorder
                                        border.width: 1
                                        visible: root.answerWidget(qdef) === "text"
                                        TextField {
                                            anchors.fill: parent
                                            anchors.leftMargin: 14
                                            anchors.rightMargin: 14
                                            color: root.wbText
                                            placeholderTextColor: root.wbTextTert
                                            font.pixelSize: 13
                                            background: null
                                            placeholderText: "Your answer"
                                            text: String(root.answerValue(qdef ? qdef.id : "") || "")
                                            onTextChanged: if (qdef) root.setAnswer(qdef.id, text)
                                            selectByMouse: true
                                        }
                                    }

                                    // Textarea
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 96
                                        radius: root.wbR2
                                        color: root.wbSurfaceRaised
                                        border.color: root.wbBorder
                                        border.width: 1
                                        visible: root.answerWidget(qdef) === "textarea"
                                        TextArea {
                                            anchors.fill: parent
                                            anchors.margins: 14
                                            color: root.wbText
                                            placeholderTextColor: root.wbTextTert
                                            font.pixelSize: 13
                                            background: null
                                            wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                            placeholderText: "Your answer"
                                            text: String(root.answerValue(qdef ? qdef.id : "") || "")
                                            onTextChanged: if (qdef) root.setAnswer(qdef.id, text)
                                            selectByMouse: true
                                        }
                                    }

                                    // Radio / Checkbox
                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: root.wbS2
                                        visible: (root.answerWidget(qdef) === "radioButtons" || root.answerWidget(qdef) === "checkbox")

                                        Repeater {
                                            model: (qdef && qdef.options) ? qdef.options.length : 0
                                            Rectangle {
                                                Layout.fillWidth: true
                                                height: 44
                                                radius: root.wbR2
                                                color: {
                                                    var sel = qdef.type === "radioButtons"
                                                        ? root.answerValue(qdef.id) === index
                                                        : (root.answerValue(qdef.id) || []).indexOf(index) >= 0;
                                                    return sel ? root.wbPrimarySubtle : root.wbSurfaceRaised;
                                                }
                                                border.color: {
                                                    var sel = qdef.type === "radioButtons"
                                                        ? root.answerValue(qdef.id) === index
                                                        : (root.answerValue(qdef.id) || []).indexOf(index) >= 0;
                                                    return sel ? root.wbPrimary : root.wbBorderSubtle;
                                                }
                                                border.width: 1

                                                RowLayout {
                                                    anchors.fill: parent
                                                    anchors.leftMargin: root.wbS4
                                                    anchors.rightMargin: root.wbS4
                                                    spacing: root.wbS3

                                                    Rectangle {
                                                        width: 18; height: 18
                                                        radius: qdef.type === "radioButtons" ? 9 : 4
                                                        color: {
                                                            var sel = qdef.type === "radioButtons"
                                                                ? root.answerValue(qdef.id) === index
                                                                : (root.answerValue(qdef.id) || []).indexOf(index) >= 0;
                                                            return sel ? root.wbPrimary : "transparent";
                                                        }
                                                        border.color: {
                                                            var sel = qdef.type === "radioButtons"
                                                                ? root.answerValue(qdef.id) === index
                                                                : (root.answerValue(qdef.id) || []).indexOf(index) >= 0;
                                                            return sel ? root.wbPrimary : root.wbBorder;
                                                        }
                                                        border.width: 2
                                                        Text {
                                                            anchors.centerIn: parent
                                                            visible: qdef.type === "checkbox" && (root.answerValue(qdef.id) || []).indexOf(index) >= 0
                                                            text: "✓"
                                                            font.pixelSize: 11
                                                            font.weight: Font.Bold
                                                            color: "white"
                                                        }
                                                    }

                                                    Text {
                                                        text: qdef.options[index]
                                                        font.pixelSize: 13
                                                        color: root.wbText
                                                    }
                                                }

                                                MouseArea {
                                                    anchors.fill: parent
                                                    cursorShape: Qt.PointingHandCursor
                                                    onClicked: {
                                                        if (qdef.type === "radioButtons") root.setAnswer(qdef.id, index);
                                                        else {
                                                            var v = (root.answerValue(qdef.id) || []).slice();
                                                            var p = v.indexOf(index);
                                                            if (p >= 0) v.splice(p, 1); else v.push(index);
                                                            v.sort(function (a, b) { return a - b; });
                                                            root.setAnswer(qdef.id, v);
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            // Submit
                            Rectangle {
                                Layout.fillWidth: true
                                height: 48
                                radius: root.wbR2
                                color: root.wbAccent
                                Text {
                                    anchors.centerIn: parent
                                    text: "Submit Response"
                                    font.pixelSize: 15
                                    font.weight: Font.Bold
                                    color: "#0b0b10"
                                }
                                MouseArea {
                                    anchors.fill: parent
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: root.doSubmit()
                                }
                            }

                            // Privacy note
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: privT.implicitHeight + 2 * root.wbS3
                                radius: root.wbR2
                                color: "#1a2a1a"
                                border.color: "#2a4d3a"
                                border.width: 1
                                Text {
                                    id: privT
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.leftMargin: root.wbS4
                                    anchors.rightMargin: root.wbS4
                                    anchors.topMargin: root.wbS3
                                    anchors.bottomMargin: root.wbS3
                                    text: "🔒 Your answers are sealed end-to-end. Only the form creator can read them. No servers, no tracking."
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: 12
                                    color: root.wbSuccess
                                }
                            }
                        }
                    }

                    // Closed note
                    Text {
                        visible: !root.isCreator(root.selectedForm) && root.selectedForm && root.selectedForm.status === "closed"
                        Layout.fillWidth: true
                        text: "This form is closed — no new responses are accepted."
                        wrapMode: Text.WordWrap
                        font.pixelSize: 13
                        color: root.wbTextTert
                    }
                }
            }
        }
    }

    // ══ CREATE FORM OVERLAY ═══════════════════════════════════════════════════
    Rectangle {
        anchors.fill: parent
        visible: root.showCreate
        color: "#cc0b0b10"
        z: 10

        Rectangle {
            width: Math.min(560, parent.width - 48)
            height: Math.min(parent.height - 48, createFlick.contentHeight + 2 * root.wbS5)
            anchors.centerIn: parent
            radius: root.wbR4
            color: root.wbSurface
            border.color: root.wbBorder
            border.width: 1

            Flickable {
                id: createFlick
                anchors.fill: parent
                contentWidth: width
                contentHeight: createCard.implicitHeight + 2 * root.wbS5
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: createCard
                    x: root.wbS5
                    y: root.wbS5
                    width: parent.width - 2 * root.wbS5
                    spacing: root.wbS4

                    RowLayout {
                        Layout.fillWidth: true
                        Text {
                            text: "New Form"
                            font.pixelSize: 22
                            font.weight: Font.Bold
                            color: root.wbText
                        }
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            width: 28; height: 28
                            radius: 14
                            color: root.wbSurfaceRaised
                            Text {
                                anchors.centerIn: parent
                                text: "✕"
                                font.pixelSize: 13
                                color: root.wbTextTert
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.showCreate = false
                            }
                        }
                    }

                    // Title
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: root.wbS2
                        Text {
                            text: "TITLE"
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                            color: root.wbTextTert
                            letterSpacing: 0.5
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            height: 44
                            radius: root.wbR2
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
                                selectByMouse: true
                            }
                        }
                    }

                    // Description
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: root.wbS2
                        Text {
                            text: "DESCRIPTION (OPTIONAL)"
                            font.pixelSize: 10
                            font.weight: Font.DemiBold
                            color: root.wbTextTert
                            letterSpacing: 0.5
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            height: 44
                            radius: root.wbR2
                            color: root.wbSurfaceRaised
                            border.color: root.wbBorder
                            border.width: 1
                            TextField {
                                id: createDesc
                                anchors.fill: parent
                                anchors.leftMargin: 14
                                anchors.rightMargin: 14
                                color: root.wbText
                                placeholderTextColor: root.wbTextTert
                                font.pixelSize: 14
                                background: null
                                placeholderText: "What's this form about?"
                                selectByMouse: true
                            }
                        }
                    }

                    // Questions
                    Text {
                        text: "QUESTIONS (" + root.draftQuestions.length + ")"
                        font.pixelSize: 10
                        font.weight: Font.DemiBold
                        color: root.wbTextTert
                        letterSpacing: 0.5
                    }

                    Repeater {
                        model: root.draftQuestions.length
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: qbCol.implicitHeight + 2 * root.wbS4
                            radius: root.wbR2
                            color: root.wbSurfaceRaised
                            border.color: root.wbBorderSubtle
                            border.width: 1

                            ColumnLayout {
                                id: qbCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.margins: root.wbS4
                                spacing: root.wbS3

                                RowLayout {
                                    spacing: root.wbS2
                                    Rectangle {
                                        width: typeB.implicitWidth + 16
                                        height: 26
                                        radius: 6
                                        color: root.wbPrimarySubtle
                                        Text {
                                            id: typeB
                                            anchors.centerIn: parent
                                            text: {
                                                var t = root.normType(root.draftQuestions[index]);
                                                var m = { "text": "Text", "textarea": "Long text", "radioButtons": "Radio", "checkbox": "Checkbox" };
                                                return m[t] || "Text";
                                            }
                                            font.pixelSize: 11
                                            font.weight: Font.DemiBold
                                            color: root.wbPrimary
                                        }
                                    }
                                    ComboBox {
                                        width: 0; height: 0
                                        visible: false
                                        model: ["text", "textarea", "radioButtons", "checkbox"]
                                        currentIndex: {
                                            var m = ["text", "textarea", "radioButtons", "checkbox"];
                                            var p = m.indexOf(root.normType(root.draftQuestions[index]));
                                            return p >= 0 ? p : 0;
                                        }
                                        onActivated: {
                                            var m = ["text", "textarea", "radioButtons", "checkbox"];
                                            root.setDraftQuestion(index, "type", m[currentIndex]);
                                        }
                                    }
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 34
                                        radius: root.wbR1
                                        color: root.wbSurface
                                        border.color: root.wbBorder
                                        border.width: 1
                                        TextField {
                                            anchors.fill: parent
                                            anchors.leftMargin: 10
                                            anchors.rightMargin: 10
                                            color: root.wbText
                                            placeholderTextColor: root.wbTextTert
                                            font.pixelSize: 13
                                            background: null
                                            placeholderText: "Question text"
                                            text: String(root.draftQuestions[index].text || "")
                                            onTextChanged: root.setDraftQuestion(index, "text", text)
                                            selectByMouse: true
                                        }
                                    }
                                    Rectangle {
                                        width: 18; height: 18
                                        radius: 4
                                        color: root.draftQuestions[index].required ? root.wbPrimary : "transparent"
                                        border.color: root.wbBorder
                                        border.width: 2
                                        Text {
                                            anchors.centerIn: parent
                                            visible: root.draftQuestions[index].required
                                            text: "✓"
                                            font.pixelSize: 11
                                            font.weight: Font.Bold
                                            color: "white"
                                        }
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.setDraftQuestion(index, "required", !root.draftQuestions[index].required)
                                        }
                                    }
                                    Text {
                                        text: "✕"
                                        font.pixelSize: 14
                                        color: root.wbTextTert
                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: root.removeDraftQuestion(index)
                                        }
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 72
                                    radius: root.wbR1
                                    color: root.wbSurface
                                    border.color: root.wbBorder
                                    border.width: 1
                                    visible: root.draftQuestions[index].type === "radioButtons" || root.draftQuestions[index].type === "checkbox"
                                    TextArea {
                                        anchors.fill: parent
                                        anchors.margins: 10
                                        color: root.wbText
                                        placeholderTextColor: root.wbTextTert
                                        font.pixelSize: 12
                                        background: null
                                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                        placeholderText: "Options — one per line (min 2)"
                                        text: String(root.draftQuestions[index].optionsText || "")
                                        onTextChanged: root.setDraftQuestion(index, "optionsText", text)
                                        selectByMouse: true
                                    }
                                }
                            }
                        }
                    }

                    // Add question
                    Rectangle {
                        Layout.fillWidth: true
                        height: 38
                        radius: root.wbR2
                        color: "transparent"
                        border.color: root.wbBorder
                        border.width: 1
                        border.style: Qt.DashLine
                        Text {
                            anchors.centerIn: parent
                            text: "+ Add question"
                            font.pixelSize: 13
                            color: root.wbTextTert
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.addDraftQuestion()
                        }
                    }

                    // Actions
                    RowLayout {
                        Layout.fillWidth: true
                        Layout.topMargin: root.wbS3
                        spacing: root.wbS3
                        Item { Layout.fillWidth: true }
                        Rectangle {
                            width: cancelB.implicitWidth + 24
                            height: 44
                            radius: root.wbR2
                            color: "transparent"
                            Text {
                                id: cancelB
                                anchors.centerIn: parent
                                text: "Cancel"
                                font.pixelSize: 14
                                color: root.wbTextTert
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.showCreate = false
                            }
                        }
                        Rectangle {
                            width: createB.implicitWidth + 32
                            height: 44
                            radius: root.wbR2
                            color: root.wbPrimary
                            Text {
                                id: createB
                                anchors.centerIn: parent
                                text: "Create & Share"
                                font.pixelSize: 14
                                font.weight: Font.Bold
                                color: "white"
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.doCreate()
                            }
                        }
                    }
                }
            }
        }
    }

    // ══ SHARE OVERLAY ═════════════════════════════════════════════════════════
    Rectangle {
        anchors.fill: parent
        visible: root.showShare
        color: "#cc0b0b10"
        z: 10

        Rectangle {
            width: Math.min(420, parent.width - 48)
            height: Math.min(parent.height - 48, shareCol.implicitHeight + 2 * root.wbS5)
            anchors.centerIn: parent
            radius: root.wbR4
            color: root.wbSurface
            border.color: root.wbBorder
            border.width: 1

            ColumnLayout {
                id: shareCol
                x: root.wbS5
                y: root.wbS5
                width: parent.width - 2 * root.wbS5
                spacing: root.wbS4

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "Share"
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: root.wbText
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 28; height: 28
                        radius: 14
                        color: root.wbSurfaceRaised
                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            font.pixelSize: 13
                            color: root.wbTextTert
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.showShare = false
                        }
                    }
                }

                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: "Anyone with this link can answer. No account needed."
                    font.pixelSize: 13
                    color: root.wbTextSec
                }

                Canvas {
                    id: shareQrCanvas
                    width: 180; height: 180
                    Layout.alignment: Qt.AlignHCenter
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.clearRect(0, 0, width, height);
                        if (!root.qrData) return;
                        var n = root.qrData.n, cells = root.qrData.cells;
                        var s = Math.min(width, height) / n;
                        ctx.fillStyle = "#ffffff";
                        ctx.fillRect(0, 0, n * s, n * s);
                        ctx.fillStyle = "#14141f";
                        for (var i = 0; i < n * n; i++) {
                            if (!cells[i]) continue;
                            var x = i % n, y = Math.floor(i / n);
                            ctx.fillRect(x * s, y * s, s + 0.5, s + 0.5);
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: shareUriT.implicitHeight + 2 * root.wbS3
                    radius: root.wbR2
                    color: root.wbSurfaceRaised
                    border.color: root.wbBorder
                    border.width: 1
                    Text {
                        id: shareUriT
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: root.wbS3
                        anchors.rightMargin: root.wbS3
                        anchors.topMargin: root.wbS3
                        anchors.bottomMargin: root.wbS3
                        text: root.shareUriText || "(building…)"
                        font.pixelSize: 11
                        font.family: "monospace"
                        color: root.wbTextSec
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        elide: Text.ElideRight
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 42
                    radius: root.wbR2
                    color: root.wbPrimary
                    Text {
                        anchors.centerIn: parent
                        text: "Copy Link"
                        font.pixelSize: 14
                        font.weight: Font.Bold
                        color: "white"
                    }
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { clip.text = root.shareUriText; clip.select(); clip.copy(); root.toast("Link copied"); }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: tipT.implicitHeight + 2 * root.wbS3
                    radius: root.wbR2
                    color: root.wbPrimarySubtle
                    Text {
                        id: tipT
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: root.wbS3
                        anchors.rightMargin: root.wbS3
                        anchors.topMargin: root.wbS3
                        anchors.bottomMargin: root.wbS3
                        text: "💡 Respondents see only the form questions. Their answers are encrypted to you alone."
                        wrapMode: Text.WordWrap
                        font.pixelSize: 12
                        color: root.wbPrimary
                    }
                }
            }
        }
    }

    // ══ CSV OVERLAY ═══════════════════════════════════════════════════════════
    Rectangle {
        anchors.fill: parent
        visible: root.showCsv
        color: "#cc0b0b10"
        z: 10

        Rectangle {
            width: Math.min(600, parent.width - 48)
            height: Math.min(parent.height - 48, csvCard.implicitHeight + 2 * root.wbS5)
            anchors.centerIn: parent
            radius: root.wbR4
            color: root.wbSurface
            border.color: root.wbBorder
            border.width: 1

            ColumnLayout {
                id: csvCard
                x: root.wbS5
                y: root.wbS5
                width: parent.width - 2 * root.wbS5
                spacing: root.wbS4

                RowLayout {
                    Layout.fillWidth: true
                    Text {
                        text: "CSV Export"
                        font.pixelSize: 20
                        font.weight: Font.Bold
                        color: root.wbText
                    }
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: 28; height: 28
                        radius: 14
                        color: root.wbSurfaceRaised
                        Text {
                            anchors.centerIn: parent
                            text: "✕"
                            font.pixelSize: 13
                            color: root.wbTextTert
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.showCsv = false
                        }
                    }
                }

                Rectangle {
                    Layout.fillWidth: true
                    height: 240
                    radius: root.wbR2
                    color: root.wbSurfaceRaised
                    border.color: root.wbBorder
                    border.width: 1
                    TextArea {
                        anchors.fill: parent
                        anchors.margins: 12
                        readOnly: true
                        color: root.wbText
                        font.pixelSize: 11
                        font.family: "monospace"
                        background: null
                        wrapMode: Text.NoWrap
                        text: root.csvText
                        selectByMouse: true
                    }
                }

                RowLayout {
                    spacing: root.wbS3
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: copyCsvB.implicitWidth + 24
                        height: 36
                        radius: root.wbR2
                        color: root.wbPrimary
                        Text {
                            id: copyCsvB
                            anchors.centerIn: parent
                            text: "Copy CSV"
                            font.pixelSize: 13
                            font.weight: Font.DemiBold
                            color: "white"
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: { clip.text = root.csvText; clip.select(); clip.copy(); root.toast("CSV copied"); }
                        }
                    }
                }
            }
        }
    }

    // ══ TOAST ═════════════════════════════════════════════════════════════════
    Rectangle {
        visible: !!root.toastMsg
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: root.wbS6
        width: Math.min(440, root.width - 32)
        implicitHeight: toastT.implicitHeight + 2 * root.wbS3
        radius: root.wbR3
        color: root.wbSurfaceRaised
        border.color: root.wbBorder
        border.width: 1
        z: 20
        Text {
            id: toastT
            anchors.centerIn: parent
            width: parent.width - 2 * root.wbS4
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.toastMsg
            font.pixelSize: 13
            color: root.wbText
        }
    }
}
