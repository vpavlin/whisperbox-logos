import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// WhisperBox — privacy-first encrypted forms over Waku.
// v0.2 design: single-column, mobile-first, dark. No sidebar.
// All logic in whisperbox_core. This view polls snapshot() and renders JSON.
//
// Screens (property-driven, no StackView — safest for Basecamp):
//   - Home: form list + join + new
//   - Detail: form (creator or respondent)
//   - Create: full-screen overlay
//   - Share: overlay (QR + URI)
//   - CSV: overlay
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

    // ── DESIGN TOKENS (from approved mockup) ──────────────────────────────────
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
    readonly property int wbRadiusSm: 8
    readonly property int wbRadiusMd: 12
    readonly property int wbRadiusLg: 16
    readonly property int wbRadiusXl: 24
    readonly property int wbSpace1: 4
    readonly property int wbSpace2: 8
    readonly property int wbSpace3: 12
    readonly property int wbSpace4: 16
    readonly property int wbSpace5: 24
    readonly property int wbSpace6: 32
    readonly property int wbSpace7: 48

    // ── STATE PLUMBING (unchanged from v0.1) ──────────────────────────────────
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
    readonly property var watchedArr: st.watched || []
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
    property string lastQrFormId: ""
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
                root.lastQrFormId = fid;
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

    // ── CLIPBOARD HACK ────────────────────────────────────────────────────────
    TextEdit { id: clip; visible: false }

    // ═══════════════════════════════════════════════════════════════════════════
    // LAYOUT — single column, no sidebar
    // ═══════════════════════════════════════════════════════════════════════════

    Rectangle {
        anchors.fill: parent
        color: root.wbBg

        // ── HOME SCREEN ───────────────────────────────────────────────────────
        Flickable {
            id: homeScreen
            anchors.fill: parent
            visible: !root.selectedForm
            clip: true
            contentWidth: width
            contentHeight: homeCol.height + root.wbSpace7
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: homeCol
                width: parent.width - 2 * root.wbSpace5
                x: root.wbSpace5
                y: root.wbSpace6
                spacing: root.wbSpace4

                // Header
                RowLayout {
                    Layout.fillWidth: true
                    spacing: root.wbSpace3
                    // Logo
                    Canvas {
                        width: 32; height: 32
                        onPaint: {
                            var ctx = getContext("2d");
                            ctx.clearRect(0, 0, 32, 32);
                            ctx.strokeStyle = root.wbPrimary;
                            ctx.lineWidth = 2;
                            ctx.lineCap = "round";
                            // Box
                            ctx.beginPath();
                            ctx.roundRect(4, 8, 24, 18, 4);
                            ctx.stroke();
                            // Handle
                            ctx.beginPath();
                            ctx.moveTo(8, 8); ctx.lineTo(8, 6);
                            ctx.quadraticCurveTo(8, 4, 10, 4);
                            ctx.lineTo(22, 4);
                            ctx.quadraticCurveTo(24, 4, 24, 6);
                            ctx.lineTo(24, 8);
                            ctx.stroke();
                            // Speech curve
                            ctx.beginPath();
                            ctx.moveTo(12, 14);
                            ctx.quadraticCurveTo(12, 12, 14, 12);
                            ctx.lineTo(18, 12);
                            ctx.quadraticCurveTo(20, 12, 20, 14);
                            ctx.lineTo(20, 16);
                            ctx.quadraticCurveTo(20, 18, 18, 18);
                            ctx.lineTo(17, 18);
                            ctx.stroke();
                        }
                    }
                    ColumnLayout {
                        spacing: 0
                        Text {
                            text: "WhisperBox"
                            font.pixelSize: 20
                            font.weight: Font.Bold
                            color: root.wbText
                        }
                        Text {
                            text: "encrypted forms over Waku"
                            font.pixelSize: 11
                            color: root.wbTextTert
                        }
                    }
                    Item { Layout.fillWidth: true }
                    // New form button
                    Rectangle {
                        width: newFormBtn.implicitWidth + 24
                        height: 36
                        radius: root.wbRadiusMd
                        color: root.wbPrimary
                        Text {
                            id: newFormBtn
                            anchors.centerIn: parent
                            text: "+ New"
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
                }

                // Join input
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.wbSpace2
                    Text {
                        text: "JOIN A FORM"
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        color: root.wbTextTert
                        letterSpacing: 0.5
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        height: 42
                        radius: root.wbRadiusMd
                        color: root.wbSurfaceRaised
                        border.color: root.wbBorder
                        border.width: 1
                        TextField {
                            id: joinField
                            anchors.fill: parent
                            anchors.leftMargin: 14
                            anchors.rightMargin: 14
                            color: root.wbText
                            placeholderTextColor: root.wbTextTert
                            font.pixelSize: 13
                            background: null
                            selectByMouse: true
                        }
                    }
                    Rectangle {
                        Layout.fillWidth: true
                        height: 34
                        radius: root.wbRadiusMd
                        color: String(joinField.text || "").trim().length > 0 ? root.wbSurfaceRaised : "transparent"
                        border.color: String(joinField.text || "").trim().length > 0 ? root.wbBorder : "transparent"
                        border.width: 1
                        Text {
                            anchors.centerIn: parent
                            text: "Join"
                            font.pixelSize: 13
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
                }

                // Form list
                Text {
                    text: "FORMS"
                    font.pixelSize: 11
                    font.weight: Font.DemiBold
                    color: root.wbTextTert
                    letterSpacing: 0.5
                }

                Repeater {
                    model: root.formList
                    Rectangle {
                        Layout.fillWidth: true
                        height: 64
                        radius: root.wbRadiusMd
                        color: root.wbSurfaceRaised
                        border.color: root.wbBorderSubtle
                        border.width: 1

                        property var f: root.formsObj[modelData]

                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: root.wbSpace3
                            spacing: root.wbSpace3

                            // Icon
                            Rectangle {
                                width: 40; height: 40
                                radius: root.wbRadiusSm
                                color: root.wbPrimarySubtle
                                Text {
                                    anchors.centerIn: parent
                                    text: "📋"
                                    font.pixelSize: 18
                                }
                            }

                            // Body
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: 2
                                Text {
                                    text: (f && f.title) ? f.title : modelData
                                    font.pixelSize: 14
                                    font.weight: Font.DemiBold
                                    color: root.wbText
                                    elide: Text.ElideRight
                                    width: parent.width
                                }
                                Text {
                                    text: {
                                        var nq = (f && f.questions) ? f.questions.length : 0;
                                        var nr = root.responsesFor(modelData).length;
                                        return nq + " question" + (nq !== 1 ? "s" : "") + (nr > 0 ? " · " + nr + " response" + (nr !== 1 ? "s" : "") : "");
                                    }
                                    font.pixelSize: 12
                                    color: root.wbTextTert
                                }
                            }

                            // Badges
                            RowLayout {
                                spacing: 6
                                Rectangle {
                                    visible: f && f.status === "open"
                                    width: openBadge.implicitWidth + 16
                                    height: 22
                                    radius: 11
                                    color: "#1a3d2a"
                                    Text {
                                        id: openBadge
                                        anchors.centerIn: parent
                                        text: "Open"
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: root.wbSuccess
                                    }
                                }
                                Rectangle {
                                    visible: f && f.status === "closed"
                                    width: closedBadge.implicitWidth + 16
                                    height: 22
                                    radius: 11
                                    color: "#1e1e30"
                                    Text {
                                        id: closedBadge
                                        anchors.centerIn: parent
                                        text: "Closed"
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: root.wbTextTert
                                    }
                                }
                                Rectangle {
                                    visible: root.isCreator(f)
                                    width: mineBadge.implicitWidth + 16
                                    height: 22
                                    radius: 11
                                    color: root.wbPrimarySubtle
                                    Text {
                                        id: mineBadge
                                        anchors.centerIn: parent
                                        text: "Mine"
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: root.wbPrimary
                                    }
                                }
                                Rectangle {
                                    visible: root.hasResponded(modelData) && !root.isCreator(f)
                                    width: ansBadge.implicitWidth + 16
                                    height: 22
                                    radius: 11
                                    color: "#1a2a3d"
                                    Text {
                                        id: ansBadge
                                        anchors.centerIn: parent
                                        text: "Answered"
                                        font.pixelSize: 11
                                        font.weight: Font.DemiBold
                                        color: "#60a5fa"
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

                // Empty state
                ColumnLayout {
                    visible: root.formList.length === 0
                    Layout.fillWidth: true
                    Layout.topMargin: root.wbSpace7
                    spacing: root.wbSpace3
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "No forms yet"
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                        color: root.wbTextSec
                    }
                    Text {
                        Layout.alignment: Qt.AlignHCenter
                        text: "Create a form or paste a link above to join one."
                        font.pixelSize: 13
                        color: root.wbTextTert
                    }
                }

                // Sync status footer
                RowLayout {
                    Layout.fillWidth: true
                    Layout.topMargin: root.wbSpace4
                    spacing: root.wbSpace2
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        color: root.nodeReady ? root.wbSuccess : root.wbWarning
                    }
                    Text {
                        text: root.nodeReady ? "Synced" : "Connecting…"
                        font.pixelSize: 12
                        color: root.wbTextTert
                    }
                    Text {
                        text: "· " + root.shortAddr(root.myAddress)
                        font.pixelSize: 12
                        color: root.wbTextTert
                    }
                    Item { Layout.fillWidth: true }
                    Text {
                        text: "rx " + (root.diag.rxRaw || 0) + " / tx " + (root.diag.txTotal || 0)
                        font.pixelSize: 11
                        color: root.wbTextTert
                    }
                }
            }
        }

        // ── DETAIL SCREEN ─────────────────────────────────────────────────────
        Flickable {
            id: detailScreen
            anchors.fill: parent
            visible: !!root.selectedForm
            clip: true
            contentWidth: width
            contentHeight: detailCol.height + 2 * root.wbSpace6
            boundsBehavior: Flickable.StopAtBounds

            ColumnLayout {
                id: detailCol
                width: parent.width - 2 * root.wbSpace5
                x: root.wbSpace5
                y: root.wbSpace5
                spacing: root.wbSpace4

                // Back button
                RowLayout {
                    spacing: root.wbSpace2
                    Rectangle {
                        width: 32; height: 32
                        radius: root.wbRadiusSm
                        color: root.wbSurfaceRaised
                        Text {
                            anchors.centerIn: parent
                            text: "←"
                            font.pixelSize: 16
                            color: root.wbTextSec
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.selectedId = ""
                        }
                    }
                    Text {
                        text: "Back to forms"
                        font.pixelSize: 13
                        color: root.wbTextTert
                    }
                }

                // Form header
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.wbSpace2
                    Text {
                        Layout.fillWidth: true
                        text: root.selectedForm ? root.selectedForm.title : ""
                        font.pixelSize: 24
                        font.weight: Font.Bold
                        color: root.wbText
                        wrapMode: Text.WordWrap
                    }
                    Text {
                        Layout.fillWidth: true
                        visible: !!(root.selectedForm && root.selectedForm.description)
                        text: root.selectedForm ? root.selectedForm.description : ""
                        font.pixelSize: 14
                        color: root.wbTextSec
                        wrapMode: Text.WordWrap
                    }
                    RowLayout {
                        spacing: root.wbSpace2
                        Rectangle {
                            visible: root.selectedForm && root.selectedForm.status === "open"
                            width: statusBadge.implicitWidth + 16
                            height: 22
                            radius: 11
                            color: "#1a3d2a"
                            Text {
                                id: statusBadge
                                anchors.centerIn: parent
                                text: "Open"
                                font.pixelSize: 11
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
                }

                // ══ CREATOR SECTION ═══════════════════════════════════════════
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.wbSpace4
                    visible: root.isCreator(root.selectedForm)

                    // Stats row
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: root.wbSpace3
                        Rectangle {
                            Layout.fillWidth: true
                            height: 72
                            radius: root.wbRadiusMd
                            color: root.wbSurfaceRaised
                            ColumnLayout {
                                anchors.centerIn: parent
                                spacing: 2
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: String(root.responsesFor(root.selectedId).length)
                                    font.pixelSize: 24
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
                            radius: root.wbRadiusMd
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
                                    font.pixelSize: 24
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
                            radius: root.wbRadiusMd
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
                                    font.pixelSize: 24
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

                    // Share button
                    Rectangle {
                        Layout.fillWidth: true
                        height: 44
                        radius: root.wbRadiusMd
                        color: root.wbSurfaceRaised
                        border.color: root.wbBorder
                        border.width: 1
                        RowLayout {
                            anchors.centerIn: parent
                            spacing: root.wbSpace2
                            Text { text: "🔗"; font.pixelSize: 14 }
                            Text {
                                text: "Share this form"
                                font.pixelSize: 14
                                font.weight: Font.DemiBold
                                color: root.wbText
                            }
                        }
                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: {
                                root.buildShare();
                                root.showShare = true;
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
                            implicitHeight: respCol.implicitHeight + 2 * root.wbSpace4
                            radius: root.wbRadiusMd
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
                                anchors.margins: root.wbSpace4
                                spacing: root.wbSpace3

                                // Response header
                                RowLayout {
                                    spacing: root.wbSpace2
                                    Text {
                                        text: root.shortAddr(resp.respondent)
                                        font.pixelSize: 12
                                        font.family: "monospace"
                                        color: root.wbTextSec
                                    }
                                    Text {
                                        text: root.fmtTime(resp.submittedAt)
                                        font.pixelSize: 11
                                        color: root.wbTextTert
                                    }
                                    Item { Layout.fillWidth: true }
                                    // Confirm button / badge
                                    Rectangle {
                                        visible: resp.confirmed !== true
                                        width: confirmBtn.implicitWidth + 20
                                        height: 26
                                        radius: 13
                                        color: root.wbPrimarySubtle
                                        Text {
                                            id: confirmBtn
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
                                        width: confBadge.implicitWidth + 16
                                        height: 22
                                        radius: 11
                                        color: "#1a3d2a"
                                        Text {
                                            id: confBadge
                                            anchors.centerIn: parent
                                            text: "✓ Confirmed"
                                            font.pixelSize: 11
                                            font.weight: Font.DemiBold
                                            color: root.wbSuccess
                                        }
                                    }
                                }

                                // Answers
                                Repeater {
                                    model: (resp.answers) ? resp.answers.length : 0
                                    RowLayout {
                                        spacing: root.wbSpace2
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

                    // Creator actions
                    RowLayout {
                        spacing: root.wbSpace3
                        Rectangle {
                            width: csvBtn.implicitWidth + 28
                            height: 38
                            radius: root.wbRadiusMd
                            color: root.wbSurfaceRaised
                            border.color: root.wbBorder
                            border.width: 1
                            Text {
                                id: csvBtn
                                anchors.centerIn: parent
                                text: "Export CSV"
                                font.pixelSize: 13
                                font.weight: Font.DemiBold
                                color: root.wbText
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.doExportCsv()
                            }
                        }
                        Rectangle {
                            visible: !(root.selectedForm && root.selectedForm.status === "closed")
                            width: closeBtn.implicitWidth + 28
                            height: 38
                            radius: root.wbRadiusMd
                            color: "#2a1a1a"
                            border.color: "#3d2020"
                            border.width: 1
                            Text {
                                id: closeBtn
                                anchors.centerIn: parent
                                text: "Close form"
                                font.pixelSize: 13
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

                // ══ RESPONDENT SECTION ════════════════════════════════════════
                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: root.wbSpace4
                    visible: !root.isCreator(root.selectedForm) && root.selectedForm && root.selectedForm.status === "open"

                    // Already responded
                    Rectangle {
                        Layout.fillWidth: true
                        visible: root.hasResponded(root.selectedId)
                        implicitHeight: alreadyResp.implicitHeight + 2 * root.wbSpace3
                        radius: root.wbRadiusMd
                        color: "#1a3d2a"
                        border.color: "#2a4d3a"
                        border.width: 1
                        Text {
                            id: alreadyResp
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            anchors.leftMargin: root.wbSpace4
                            anchors.rightMargin: root.wbSpace4
                            anchors.topMargin: root.wbSpace3
                            anchors.bottomMargin: root.wbSpace3
                            text: "✓ You already responded to this form. The creator will see your sealed answers."
                            wrapMode: Text.WordWrap
                            font.pixelSize: 13
                            color: root.wbSuccess
                        }
                    }

                    // Answer form
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: root.wbSpace5
                        visible: !root.hasResponded(root.selectedId)

                        // Waiting state
                        Text {
                            Layout.fillWidth: true
                            visible: (root.selectedForm && root.selectedForm.questions) ? root.selectedForm.questions.length === 0 : false
                            text: "Waiting for form data — it arrives over the mesh shortly."
                            wrapMode: Text.WordWrap
                            font.pixelSize: 13
                            color: root.wbTextTert
                        }

                        // Questions
                        Repeater {
                            model: (root.selectedForm && root.selectedForm.questions) ? root.selectedForm.questions.length : 0
                            ColumnLayout {
                                Layout.fillWidth: true
                                spacing: root.wbSpace3
                                property var qdef: (root.selectedForm && root.selectedForm.questions) ? root.selectedForm.questions[index] : null

                                // Question label
                                Text {
                                    Layout.fillWidth: true
                                    text: qdef ? qdef.text + (qdef.required ? " *" : "") : ""
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: 15
                                    font.weight: Font.DemiBold
                                    color: root.wbText
                                }

                                // Text input
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 44
                                    radius: root.wbRadiusMd
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
                                        font.pixelSize: 14
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
                                    radius: root.wbRadiusMd
                                    color: root.wbSurfaceRaised
                                    border.color: root.wbBorder
                                    border.width: 1
                                    visible: root.answerWidget(qdef) === "textarea"
                                    TextArea {
                                        anchors.fill: parent
                                        anchors.margins: 14
                                        color: root.wbText
                                        placeholderTextColor: root.wbTextTert
                                        font.pixelSize: 14
                                        background: null
                                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                                        placeholderText: "Your answer"
                                        text: String(root.answerValue(qdef ? qdef.id : "") || "")
                                        onTextChanged: if (qdef) root.setAnswer(qdef.id, text)
                                        selectByMouse: true
                                    }
                                }

                                // Radio / Checkbox options
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: root.wbSpace2
                                    visible: (root.answerWidget(qdef) === "radioButtons" || root.answerWidget(qdef) === "checkbox")

                                    Repeater {
                                        model: (qdef && qdef.options) ? qdef.options.length : 0
                                        Rectangle {
                                            Layout.fillWidth: true
                                            height: 44
                                            radius: root.wbRadiusMd
                                            color: {
                                                var selected = qdef.type === "radioButtons"
                                                    ? root.answerValue(qdef.id) === index
                                                    : (root.answerValue(qdef.id) || []).indexOf(index) >= 0;
                                                return selected ? root.wbPrimarySubtle : root.wbSurfaceRaised;
                                            }
                                            border.color: {
                                                var selected = qdef.type === "radioButtons"
                                                    ? root.answerValue(qdef.id) === index
                                                    : (root.answerValue(qdef.id) || []).indexOf(index) >= 0;
                                                return selected ? root.wbPrimary : root.wbBorderSubtle;
                                            }
                                            border.width: 1

                                            RowLayout {
                                                anchors.fill: parent
                                                anchors.leftMargin: root.wbSpace4
                                                anchors.rightMargin: root.wbSpace4
                                                spacing: root.wbSpace3

                                                // Radio/checkbox indicator
                                                Rectangle {
                                                    width: 18; height: 18
                                                    radius: qdef.type === "radioButtons" ? 9 : 4
                                                    color: {
                                                        var selected = qdef.type === "radioButtons"
                                                            ? root.answerValue(qdef.id) === index
                                                            : (root.answerValue(qdef.id) || []).indexOf(index) >= 0;
                                                        return selected ? root.wbPrimary : "transparent";
                                                    }
                                                    border.color: {
                                                        var selected = qdef.type === "radioButtons"
                                                            ? root.answerValue(qdef.id) === index
                                                            : (root.answerValue(qdef.id) || []).indexOf(index) >= 0;
                                                        return selected ? root.wbPrimary : root.wbBorder;
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
                                                    font.pixelSize: 14
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

                        // Submit button
                        Rectangle {
                            Layout.fillWidth: true
                            height: 48
                            radius: root.wbRadiusMd
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
                            implicitHeight: privacyNote.implicitHeight + 2 * root.wbSpace3
                            radius: root.wbRadiusMd
                            color: "#1a2a1a"
                            border.color: "#2a4d3a"
                            border.width: 1
                            Text {
                                id: privacyNote
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.leftMargin: root.wbSpace4
                                anchors.rightMargin: root.wbSpace4
                                anchors.topMargin: root.wbSpace3
                                anchors.bottomMargin: root.wbSpace3
                                text: "🔒 Your answers are sealed end-to-end. Only the form creator can read them. No servers, no tracking."
                                wrapMode: Text.WordWrap
                                font.pixelSize: 12
                                color: root.wbSuccess
                            }
                        }
                    }
                }

                // Closed form note
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

    // ══ CREATE FORM OVERLAY ═══════════════════════════════════════════════════
    Rectangle {
        anchors.fill: parent
        visible: root.showCreate
        color: "#cc0b0b10"
        z: 10

        Rectangle {
            width: Math.min(560, parent.width - 32)
            height: Math.min(parent.height - 32, createFlick.contentHeight + 2 * root.wbSpace5)
            anchors.centerIn: parent
            radius: root.wbRadiusXl
            color: root.wbSurface
            border.color: root.wbBorder
            border.width: 1

            Flickable {
                id: createFlick
                anchors.fill: parent
                contentWidth: width
                contentHeight: createCard.implicitHeight + 2 * root.wbSpace5
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                ColumnLayout {
                    id: createCard
                    x: root.wbSpace5
                    y: root.wbSpace5
                    width: parent.width - 2 * root.wbSpace5
                    spacing: root.wbSpace4

                    // Header
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
                        spacing: root.wbSpace2
                        Text {
                            text: "TITLE"
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            color: root.wbTextTert
                            letterSpacing: 0.5
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            height: 44
                            radius: root.wbRadiusMd
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
                        spacing: root.wbSpace2
                        Text {
                            text: "DESCRIPTION (OPTIONAL)"
                            font.pixelSize: 11
                            font.weight: Font.DemiBold
                            color: root.wbTextTert
                            letterSpacing: 0.5
                        }
                        Rectangle {
                            Layout.fillWidth: true
                            height: 44
                            radius: root.wbRadiusMd
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
                        font.pixelSize: 11
                        font.weight: Font.DemiBold
                        color: root.wbTextTert
                        letterSpacing: 0.5
                    }

                    Repeater {
                        model: root.draftQuestions.length
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: qbCol.implicitHeight + 2 * root.wbSpace4
                            radius: root.wbRadiusMd
                            color: root.wbSurfaceRaised
                            border.color: root.wbBorderSubtle
                            border.width: 1

                            ColumnLayout {
                                id: qbCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.bottom: parent.bottom
                                anchors.margins: root.wbSpace4
                                spacing: root.wbSpace3

                                // Type + text + remove
                                RowLayout {
                                    spacing: root.wbSpace2
                                    // Type badge
                                    Rectangle {
                                        width: typeBadge.implicitWidth + 16
                                        height: 26
                                        radius: 6
                                        color: root.wbPrimarySubtle
                                        Text {
                                            id: typeBadge
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
                                    // Type selector (invisible combo)
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
                                    // Question text
                                    Rectangle {
                                        Layout.fillWidth: true
                                        height: 34
                                        radius: root.wbRadiusSm
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
                                    // Required checkbox
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
                                    // Remove
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

                                // Options (for radio/checkbox)
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: 72
                                    radius: root.wbRadiusSm
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
                        radius: root.wbRadiusMd
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
                        Layout.topMargin: root.wbSpace3
                        spacing: root.wbSpace3
                        Rectangle {
                            Layout.fillWidth: true
                            height: 44
                            radius: root.wbRadiusMd
                            color: root.wbPrimary
                            Text {
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
                        Rectangle {
                            width: cancelBtn.implicitWidth + 24
                            height: 44
                            radius: root.wbRadiusMd
                            color: "transparent"
                            Text {
                                id: cancelBtn
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
            width: Math.min(420, parent.width - 32)
            height: Math.min(parent.height - 32, shareCol.implicitHeight + 2 * root.wbSpace5)
            anchors.centerIn: parent
            radius: root.wbRadiusXl
            color: root.wbSurface
            border.color: root.wbBorder
            border.width: 1

            ColumnLayout {
                id: shareCol
                x: root.wbSpace5
                y: root.wbSpace5
                width: parent.width - 2 * root.wbSpace5
                spacing: root.wbSpace4

                // Header
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

                // QR
                Canvas {
                    id: qrCanvas
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

                // URI
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: uriText.implicitHeight + 2 * root.wbSpace3
                    radius: root.wbRadiusMd
                    color: root.wbSurfaceRaised
                    border.color: root.wbBorder
                    border.width: 1
                    Text {
                        id: uriText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: root.wbSpace3
                        anchors.rightMargin: root.wbSpace3
                        anchors.topMargin: root.wbSpace3
                        anchors.bottomMargin: root.wbSpace3
                        text: root.shareUriText || "(building…)"
                        font.pixelSize: 11
                        font.family: "monospace"
                        color: root.wbTextSec
                        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
                        elide: Text.ElideRight
                    }
                }

                // Copy button
                Rectangle {
                    Layout.fillWidth: true
                    height: 42
                    radius: root.wbRadiusMd
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

                // Privacy tip
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: tipText.implicitHeight + 2 * root.wbSpace3
                    radius: root.wbRadiusMd
                    color: root.wbPrimarySubtle
                    Text {
                        id: tipText
                        anchors.left: parent.left
                        anchors.right: parent.right
                        anchors.top: parent.top
                        anchors.bottom: parent.bottom
                        anchors.leftMargin: root.wbSpace3
                        anchors.rightMargin: root.wbSpace3
                        anchors.topMargin: root.wbSpace3
                        anchors.bottomMargin: root.wbSpace3
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
            width: Math.min(600, parent.width - 32)
            height: Math.min(parent.height - 32, csvCard.implicitHeight + 2 * root.wbSpace5)
            anchors.centerIn: parent
            radius: root.wbRadiusXl
            color: root.wbSurface
            border.color: root.wbBorder
            border.width: 1

            ColumnLayout {
                id: csvCard
                x: root.wbSpace5
                y: root.wbSpace5
                width: parent.width - 2 * root.wbSpace5
                spacing: root.wbSpace4

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
                    radius: root.wbRadiusMd
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
                    spacing: root.wbSpace3
                    Item { Layout.fillWidth: true }
                    Rectangle {
                        width: copyCsvBtn.implicitWidth + 24
                        height: 36
                        radius: root.wbRadiusMd
                        color: root.wbPrimary
                        Text {
                            id: copyCsvBtn
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
        anchors.bottomMargin: root.wbSpace6
        width: Math.min(440, root.width - 32)
        implicitHeight: toastText.implicitHeight + 2 * root.wbSpace3
        radius: root.wbRadiusLg
        color: root.wbSurfaceRaised
        border.color: root.wbBorder
        border.width: 1
        z: 20
        Text {
            id: toastText
            anchors.centerIn: parent
            width: parent.width - 2 * root.wbSpace4
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.toastMsg
            font.pixelSize: 13
            color: root.wbText
        }
    }
}
