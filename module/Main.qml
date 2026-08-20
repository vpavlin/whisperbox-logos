import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import Logos.Theme
import Logos.Controls

// WhisperBox pure-QML view — privacy-first encrypted forms over Waku.
// It NEVER folds, merges or decrypts: all logic is in whisperbox_core. It polls
// the core's snapshot() action on a Timer (events are not reliably delivered to
// QML across Basecamp versions) and renders the returned JSON. Mutations call
// the core and re-render from the call's own fresh return.
//
// Layout: LEFT SIDEBAR (header, + New Form, join-by-URI/id, form list, sync
// status footer) + MAIN PANE (form detail: creator view with share card / QR /
// decrypted response table / CSV export / close, or the respondent answer flow).
//
// Styling uses the official Logos design system (Logos.Theme + Logos.Controls).
// Only LogosText + LogosButton are used as Logos* types (the proven-safe 0.2.x
// baseline); inputs are plain QtQuick controls styled with Theme tokens.

Item {
    id: root
    anchors.fill: parent

    // ── state plumbing (read-state rule: snapshot() action + poll + event) ─────
    property string stateJson: "{}"
    property var st: ({})

    // Token-styled text input (safe on every Basecamp version).
    component AppField: TextField {
        color: Theme.palette.text
        placeholderTextColor: Theme.palette.textTertiary
        selectByMouse: true
        leftPadding: Theme.spacing.small
        rightPadding: Theme.spacing.small
        background: Rectangle {
            radius: Theme.spacing.radiusSmall
            color: Theme.palette.surface
            border.color: Theme.palette.border
            border.width: 1
        }
    }
    // Token-styled multi-line input.
    component AppArea: TextArea {
        color: Theme.palette.text
        placeholderTextColor: Theme.palette.textTertiary
        selectByMouse: true
        wrapMode: Text.WrapAtWordBoundaryOrAnywhere
        leftPadding: Theme.spacing.small
        rightPadding: Theme.spacing.small
        topPadding: Theme.spacing.small
        bottomPadding: Theme.spacing.small
        background: Rectangle {
            radius: Theme.spacing.radiusSmall
            color: Theme.palette.surface
            border.color: Theme.palette.border
            border.width: 1
        }
    }
    // Token-styled combo (light styling only — core QtQuick.Controls).
    component AppCombo: ComboBox {
        implicitHeight: 36
        contentItem: Text {
            leftPadding: Theme.spacing.small
            text: displayText
            font: parent.font
            color: Theme.palette.text
            verticalAlignment: Qt.AlignVCenter
        }
        background: Rectangle {
            radius: Theme.spacing.radiusSmall
            color: Theme.palette.surface
            border.color: Theme.palette.border
            border.width: 1
        }
    }
    // Off-screen helper for Copy buttons (base QML has no Clipboard type).
    TextEdit { id: clip; visible: false }

    function callCore(m, a) {
        if (typeof logos === "undefined" || !logos.callModule) return "";
        return String(logos.callModule("whisperbox_core", m, a || []));
    }
    // Bridge may return raw JSON or a quoted/escaped JSON string — accept both.
    function asState(raw) {
        var s = String(raw || "").trim();
        for (var i = 0; i < 2 && s.charAt(0) === '"'; i++) { try { s = String(JSON.parse(s)).trim(); } catch (e) { return null; } }
        if (s.charAt(0) !== "{") return null;
        var o; try { o = JSON.parse(s); } catch (e) { return null; }
        return (o && o.error === undefined) ? o : null;
    }
    // Multi-instance guard: never let an empty-state poll blank a populated view.
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
    // Keep the pane useful: if nothing valid is selected, show the first open form.
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
                 // Self-healing share build: onSelectedIdChanged can be missed
                 // (e.g. selection set before handler active, or multi-instance
                 // races) - retry from the poll until it succeeds.
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

    // ── derived state ───────────────────────────────────────────────────────────
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
        return a.length > 14 ? a.substr(0, 6) + "..." + a.substr(-4) : a;
    }
    function fmtTime(ms) {
        if (!ms) return "-";
        try { return new Date(Number(ms)).toLocaleString(); } catch (e) { return String(ms); }
    }
    // Form list order: open forms in feed (HLC publish) order, then the rest.
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

    // ── create-form draft state ─────────────────────────────────────────────────
    property bool showCreate: false
    property var draftQuestions: []   // [{type, text, required, optionsText}]
    function addDraftQuestion() {
        root.draftQuestions = root.draftQuestions.concat([{ type: "text", text: "", required: true, optionsText: "" }]);
    }
    function removeDraftQuestion(idx) {
        var arr = root.draftQuestions.slice(); arr.splice(idx, 1); root.draftQuestions = arr;
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

    // ── join ────────────────────────────────────────────────────────────────────
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

    // ── share / QR (creator only, deferred — never during load/bindings) ────────
    property string shareUriText: ""
    property var qrData: null
    property string lastQrFormId: ""
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
        if (root.selectedForm && root.isCreator(root.selectedForm)) Qt.callLater(root.buildShare);
        else { root.shareUriText = ""; root.qrData = null; }
    }

    // ── respondent answer draft ─────────────────────────────────────────────────
    property var draftAnswers: ({})   // questionId -> string | int | int[]
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

    // ── CSV popup ───────────────────────────────────────────────────────────────
    property bool showCsv: false
    property string csvText: ""
    function doExportCsv() {
        if (!root.selectedForm) return;
        var r = asState(callCore("exportCsv", [root.selectedForm.id]));
        if (r && r.ok && r.csv !== undefined) { root.csvText = String(r.csv); root.showCsv = true; }
        else root.toast(r && r.error ? r.error : "Export failed");
    }

    // ── layout ──────────────────────────────────────────────────────────────────
    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ══ SIDEBAR ════════════════════════════════════════════════════════════
        Rectangle {
            Layout.preferredWidth: 320
            Layout.fillHeight: true
            color: Theme.palette.surface
            border.color: Theme.palette.borderHairline
            border.width: 1

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: Theme.spacing.medium
                spacing: Theme.spacing.small

                LogosText {
                    text: "WhisperBox"
                    font.pixelSize: Theme.typography.panelTitleText
                    font.weight: Theme.typography.weightBold
                }
                LogosText {
                    text: "encrypted forms over Waku"
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                }

                LogosButton {
                    Layout.fillWidth: true
                    implicitHeight: 42
                    text: "+ New Form"
                    onClicked: root.showCreate = true
                }

                ColumnLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny
                    LogosText {
                        text: "JOIN A FORM"
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.secondaryText
                    }
                    AppField {
                        id: joinField
                        Layout.fillWidth: true
                        implicitHeight: 36
                        placeholderText: "whisperbox:// URI or form id"
                    }
                    LogosButton {
                        Layout.fillWidth: true
                        implicitHeight: 34
                        text: "Join"
                        enabled: String(joinField.text || "").trim().length > 0
                        onClicked: root.doJoin()
                    }
                }

                Item { Layout.preferredHeight: 1 }

                LogosText {
                    text: "FORMS"
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                }

                ListView {
                    id: formListVw
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    model: root.formList
                    delegate: Rectangle {
                        width: formListVw.width
                        height: 58
                        radius: Theme.spacing.radiusSmall
                        color: modelData === root.selectedId ? Theme.palette.surfaceRaised : "transparent"
                        LogosText {
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.right: parent.right
                            anchors.margins: Theme.spacing.small
                            text: (root.formsObj[modelData] && root.formsObj[modelData].title) ? root.formsObj[modelData].title : modelData
                            elide: Text.ElideRight
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        RowLayout {
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.margins: Theme.spacing.small
                            spacing: 6
                            LogosText {
                                text: (root.formsObj[modelData] && root.formsObj[modelData].status === "closed") ? "closed" : "open"
                                color: (root.formsObj[modelData] && root.formsObj[modelData].status === "closed")
                                    ? Theme.palette.textTertiary : Theme.palette.success
                                font.pixelSize: Theme.typography.secondaryText
                            }
                            LogosText {
                                visible: root.isCreator(root.formsObj[modelData])
                                text: "mine"
                                color: Theme.palette.primary
                                font.pixelSize: Theme.typography.secondaryText
                            }
                        }
                        MouseArea { anchors.fill: parent; onClicked: root.selectedId = modelData }
                    }
                }

                // sync status footer
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Theme.spacing.tiny
                    Rectangle {
                        width: 8; height: 8; radius: 4
                        color: root.nodeReady ? Theme.palette.success : Theme.palette.warning
                    }
                    LogosText {
                        text: root.nodeReady ? "synced" : "connecting..."
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.secondaryText
                    }
                }
                LogosText {
                    text: "identity " + root.shortAddr(root.myAddress)
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                }
                LogosText {
                    text: "rx " + (root.diag.rxRaw || 0) + "  tx " + (root.diag.txTotal || 0)
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                }
            }
        }

        // ══ MAIN PANE ══════════════════════════════════════════════════════════
        Rectangle {
            Layout.fillWidth: true
            Layout.fillHeight: true
            color: Theme.palette.surface  // opaque bg: Basecamp host is white; bare Item let it show through (vision UI review 2026-08-19)

            // empty state
            ColumnLayout {
                visible: !root.selectedForm
                anchors.centerIn: parent
                spacing: Theme.spacing.small
                LogosText {
                    text: "No form selected"
                    font.pixelSize: Theme.typography.panelTitleText
                    font.weight: Theme.typography.weightBold
                    Layout.alignment: Qt.AlignHCenter
                }
                LogosText {
                    text: "Create a form or join one from the sidebar."
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                    Layout.alignment: Qt.AlignHCenter
                }
            }

            // form detail
            Flickable {
                visible: !!root.selectedForm
                anchors.fill: parent
                clip: true
                contentWidth: width
                contentHeight: detailCol.height + 2 * Theme.spacing.large

                ColumnLayout {
                    id: detailCol
                    width: parent.width - 2 * Theme.spacing.large
                    x: Theme.spacing.large
                    y: Theme.spacing.large
                    spacing: Theme.spacing.medium

                    // ── header ──
                    LogosText {
                        Layout.fillWidth: true
                        text: root.selectedForm ? root.selectedForm.title : ""
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.typography.panelTitleText
                        font.weight: Theme.typography.weightBold
                    }
                    LogosText {
                        Layout.fillWidth: true
                        visible: !!(root.selectedForm && root.selectedForm.description)
                        text: root.selectedForm ? root.selectedForm.description : ""
                        wrapMode: Text.WordWrap
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.secondaryText
                    }
                    RowLayout {
                        spacing: 8
                        LogosText {
                            text: (root.selectedForm && root.selectedForm.status === "closed") ? "CLOSED" : "OPEN"
                            color: (root.selectedForm && root.selectedForm.status === "closed")
                                ? Theme.palette.textTertiary : Theme.palette.success
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        LogosText {
                            text: "by " + root.shortAddr(root.selectedForm ? root.selectedForm.creator : "")
                            color: Theme.palette.textTertiary
                            font.pixelSize: Theme.typography.secondaryText
                        }
                        LogosText {
                            text: root.selectedId
                            color: Theme.palette.textTertiary
                            font.pixelSize: Theme.typography.secondaryText
                        }
                    }

                    // ══ CREATOR SECTION ════════════════════════════════════════
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        visible: root.isCreator(root.selectedForm)

                        // share card
                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: shareRow.implicitHeight + 2 * Theme.spacing.medium
                            radius: Theme.spacing.radiusMedium
                            color: Theme.palette.surface
                            border.color: Theme.palette.borderHairline
                            border.width: 1

                            RowLayout {
                                id: shareRow
                                anchors.centerIn: parent
                                width: parent.width - 2 * Theme.spacing.medium
                                spacing: Theme.spacing.medium

                                Canvas {
                                    id: qrCanvas
                                    width: 132; height: 132
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
                                    spacing: Theme.spacing.tiny
                                    LogosText {
                                        text: "SHARE"
                                        color: Theme.palette.textTertiary
                                        font.pixelSize: Theme.typography.secondaryText
                                    }
                                    AppField {
                                        Layout.fillWidth: true
                                        implicitHeight: 34
                                        readOnly: true
                                        selectByMouse: true
                                        text: root.shareUriText
                                    }
                                    RowLayout {
                                        spacing: Theme.spacing.tiny
                                        LogosButton {
                                            implicitHeight: 30
                                            text: "Copy link"
                                            onClicked: { clip.text = root.shareUriText; clip.select(); clip.copy(); root.toast("Link copied"); }
                                        }
                                        LogosText {
                                            text: "respondents scan the QR or open the link on their device"
                                            color: Theme.palette.textTertiary
                                            font.pixelSize: Theme.typography.secondaryText
                                        }
                                    }
                                }
                            }
                        }

                        // responses table
                        RowLayout {
                            spacing: 6
                            LogosText {
                                text: "RESPONSES (" + root.responsesFor(root.selectedId).length + ")"
                                font.pixelSize: Theme.typography.secondaryText
                                font.weight: Theme.typography.weightMedium
                            }
                            LogosText {
                                visible: root.creatorView !== null && root.creatorView.undecrypted > 0
                                text: root.creatorView ? root.creatorView.undecrypted + " undecryptable blob(s) ignored" : ""
                                color: Theme.palette.warning
                                font.pixelSize: Theme.typography.secondaryText
                            }
                        }

                        Repeater {
                            model: root.responsesFor(root.selectedId)
                            Rectangle {
                                Layout.fillWidth: true
                                implicitHeight: respCol.implicitHeight + 2 * Theme.spacing.small
                                radius: Theme.spacing.radiusSmall
                                color: Theme.palette.surface
                                border.color: Theme.palette.borderHairline
                                border.width: 1
                                property var resp: modelData   // outer delegate data (inner repeaters shadow modelData)

                                ColumnLayout {
                                    id: respCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.bottom: parent.bottom
                                    anchors.margins: Theme.spacing.small
                                    spacing: Theme.spacing.tiny

                                    RowLayout {
                                        spacing: 6
                                        LogosText {
                                            text: root.shortAddr(resp.respondent)
                                            font.pixelSize: Theme.typography.secondaryText
                                            font.weight: Theme.typography.weightMedium
                                        }
                                        LogosText {
                                            text: root.fmtTime(resp.submittedAt)
                                            color: Theme.palette.textTertiary
                                            font.pixelSize: Theme.typography.secondaryText
                                        }
                                        Item { Layout.fillWidth: true }
                                        LogosText {
                                            visible: resp.confirmed === true
                                            text: "confirmed"
                                            color: Theme.palette.success
                                            font.pixelSize: Theme.typography.secondaryText
                                        }
                                        LogosButton {
                                            visible: resp.confirmed !== true
                                            implicitHeight: 26
                                            text: "Confirm"
                                            onClicked: root.mutate("confirmResponse", [root.selectedId, resp.respondent])
                                        }
                                    }

                                    Repeater {
                                        model: (resp.answers) ? resp.answers.length : 0
                                        RowLayout {
                                            spacing: Theme.spacing.tiny
                                            LogosText {
                                                text: {
                                                    var q = null;
                                                    if (root.selectedForm && root.selectedForm.questions) {
                                                        for (var i = 0; i < root.selectedForm.questions.length; i++) {
                                                            if (root.selectedForm.questions[i].id === resp.answers[index].questionId) { q = root.selectedForm.questions[i]; break; }
                                                        }
                                                    }
                                                    return (q ? q.text : resp.answers[index].questionId) + ":  ";
                                                }
                                                color: Theme.palette.textTertiary
                                                font.pixelSize: Theme.typography.secondaryText
                                            }
                                            LogosText {
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
                                                    if (q && (q.type === "radioButtons") && q.options) return q.options[v] !== undefined ? q.options[v] : String(v);
                                                    if (q && (q.type === "checkbox") && q.options) {
                                                        var parts = [];
                                                        for (var j = 0; j < v.length; j++) parts.push(q.options[v[j]] !== undefined ? q.options[v[j]] : String(v[j]));
                                                        return parts.join(", ");
                                                    }
                                                    return String(v);
                                                }
                                                font.pixelSize: Theme.typography.secondaryText
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        // creator actions
                        RowLayout {
                            spacing: Theme.spacing.tiny
                            LogosButton {
                                implicitHeight: 36
                                text: "Export CSV"
                                onClicked: root.doExportCsv()
                            }
                            LogosButton {
                                visible: !(root.selectedForm && root.selectedForm.status === "closed")
                                implicitHeight: 36
                                text: "Close form"
                                onClicked: {
                                    var r = root.mutate("closeForm", [root.selectedId]);
                                    if (r && r.ok) root.toast("Form closed");
                                    else root.toast(r && r.error ? r.error : "Could not close form");
                                }
                            }
                        }
                    }

                    // ══ RESPONDENT SECTION ═════════════════════════════════════
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.small
                        visible: !root.isCreator(root.selectedForm) && root.selectedForm && root.selectedForm.status === "open"

                        LogosText {
                            visible: root.hasResponded(root.selectedId)
                            text: "You already responded to this form. The creator will see your sealed answers."
                            wrapMode: Text.WordWrap
                            color: Theme.palette.success
                            font.pixelSize: Theme.typography.secondaryText
                        }

                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: Theme.spacing.medium
                            visible: !root.hasResponded(root.selectedId)

                            Repeater {
                                model: (root.selectedForm && root.selectedForm.questions) ? root.selectedForm.questions.length : 0
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: Theme.spacing.tiny
                                    property var qdef: (root.selectedForm && root.selectedForm.questions) ? root.selectedForm.questions[index] : null

                                    LogosText {
                                        text: qdef ? qdef.text + (qdef.required ? " *" : "") : ""
                                        wrapMode: Text.WordWrap
                                        font.pixelSize: Theme.typography.secondaryText
                                    }

                                    AppField {
                                        Layout.fillWidth: true
                                        implicitHeight: 38
                                        visible: qdef && qdef.type === "text"
                                        placeholderText: "Your answer"
                                        text: String(root.answerValue(qdef ? qdef.id : "") || "")
                                        onTextChanged: if (qdef) root.setAnswer(qdef.id, text)
                                    }
                                    AppArea {
                                        Layout.fillWidth: true
                                        implicitHeight: 90
                                        visible: qdef && qdef.type === "textarea"
                                        placeholderText: "Your answer"
                                        text: String(root.answerValue(qdef ? qdef.id : "") || "")
                                        onTextChanged: if (qdef) root.setAnswer(qdef.id, text)
                                    }

                                    ColumnLayout {
                                        Layout.fillWidth: true
                                        spacing: 2
                                        visible: qdef && (qdef.type === "radioButtons" || qdef.type === "checkbox")

                                        Repeater {
                                            model: (qdef && qdef.options) ? qdef.options.length : 0
                                            RowLayout {
                                                spacing: Theme.spacing.small
                                                Rectangle {
                                                    width: 18; height: 18
                                                    radius: (qdef.type === "radioButtons") ? 9 : 4
                                                    color: "transparent"
                                                    border.color: Theme.palette.border
                                                    border.width: 2
                                                    Rectangle {
                                                        anchors.centerIn: parent
                                                        width: 10; height: 10
                                                        radius: (qdef.type === "radioButtons") ? 5 : 2
                                                        color: Theme.palette.primary
                                                        visible: qdef.type === "radioButtons"
                                                            ? root.answerValue(qdef.id) === index
                                                            : (root.answerValue(qdef.id) || []).indexOf(index) >= 0
                                                    }
                                                }
                                                LogosText {
                                                    text: qdef.options[index]
                                                    font.pixelSize: Theme.typography.secondaryText
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

                            LogosButton {
                                implicitHeight: 40
                                text: "Submit response"
                                onClicked: root.doSubmit()
                            }
                            LogosText {
                                text: "Your answers are sealed end-to-end. Only the form creator can read them."
                                color: Theme.palette.textTertiary
                                font.pixelSize: Theme.typography.secondaryText
                            }
                        }
                    }

                    // ══ CLOSED / VIEWER NOTE ═══════════════════════════════════
                    LogosText {
                        visible: !root.isCreator(root.selectedForm) && root.selectedForm && root.selectedForm.status === "closed"
                        text: "This form is closed — no new responses are accepted."
                        color: Theme.palette.textTertiary
                        font.pixelSize: Theme.typography.secondaryText
                    }
                }
            }
        }
    }

    // ══ CREATE-FORM OVERLAY ════════════════════════════════════════════════════
    Rectangle {
        id: createOverlay
        anchors.fill: parent
        visible: root.showCreate
        color: "#80000000"
        z: 10

        Rectangle {
            width: Math.min(560, parent.width - 48)
            height: Math.min(parent.height - 48, createCard.implicitHeight + 2 * Theme.spacing.large)
            anchors.centerIn: parent
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surfaceRaised
            border.color: Theme.palette.border
            border.width: 1

            ColumnLayout {
                id: createCard
                width: parent.width - 2 * Theme.spacing.large
                x: Theme.spacing.large
                y: Theme.spacing.large
                spacing: Theme.spacing.small

                LogosText {
                    text: "New form"
                    font.pixelSize: Theme.typography.panelTitleText
                    font.weight: Theme.typography.weightBold
                }
                AppField {
                    id: createTitle
                    Layout.fillWidth: true
                    implicitHeight: 38
                    placeholderText: "Form title (required)"
                }
                AppField {
                    id: createDesc
                    Layout.fillWidth: true
                    implicitHeight: 38
                    placeholderText: "Description (optional)"
                }

                LogosText {
                    text: "QUESTIONS (" + root.draftQuestions.length + ")"
                    color: Theme.palette.textTertiary
                    font.pixelSize: Theme.typography.secondaryText
                }

                Repeater {
                    model: root.draftQuestions.length
                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: Theme.spacing.tiny

                        RowLayout {
                            spacing: Theme.spacing.tiny
                            AppCombo {
                                width: 132
                                model: ["text", "textarea", "radioButtons", "checkbox"]
                                currentIndex: {
                                    var t = root.draftQuestions[index].type;
                                    var m = ["text", "textarea", "radioButtons", "checkbox"];
                                    var p = m.indexOf(t);
                                    return p >= 0 ? p : 0;
                                }
                                onActivated: root.setDraftQuestion(index, "type", modelData)
                            }
                            AppField {
                                Layout.fillWidth: true
                                implicitHeight: 36
                                placeholderText: "Question text"
                                text: String(root.draftQuestions[index].text || "")
                                onTextChanged: root.setDraftQuestion(index, "text", text)
                            }
                            RowLayout {
                                spacing: 4
                                LogosText {
                                    text: "required"
                                    color: Theme.palette.textTertiary
                                    font.pixelSize: Theme.typography.secondaryText
                                }
                                Rectangle {
                                    width: 18; height: 18
                                    radius: 4
                                    color: root.draftQuestions[index].required ? Theme.palette.primary : "transparent"
                                    border.color: Theme.palette.border
                                    border.width: 2
                                    MouseArea {
                                        anchors.fill: parent
                                        onClicked: root.setDraftQuestion(index, "required", !root.draftQuestions[index].required)
                                    }
                                }
                            }
                            LogosButton {
                                implicitHeight: 30
                                text: "x"
                                onClicked: root.removeDraftQuestion(index)
                            }
                        }

                        AppArea {
                            Layout.fillWidth: true
                            implicitHeight: 72
                            visible: root.draftQuestions[index].type === "radioButtons" || root.draftQuestions[index].type === "checkbox"
                            placeholderText: "Options — one per line (min 2)"
                            text: String(root.draftQuestions[index].optionsText || "")
                            onTextChanged: root.setDraftQuestion(index, "optionsText", text)
                        }
                    }
                }

                LogosButton {
                    implicitHeight: 34
                    text: "+ Add question"
                    onClicked: root.addDraftQuestion()
                }

                RowLayout {
                    spacing: Theme.spacing.tiny
                    Item { Layout.fillWidth: true }
                    LogosButton {
                        implicitHeight: 38
                        text: "Cancel"
                        onClicked: root.showCreate = false
                    }
                    LogosButton {
                        implicitHeight: 38
                        text: "Create form"
                        onClicked: root.doCreate()
                    }
                }
            }
        }
    }

    // ══ CSV POPUP ══════════════════════════════════════════════════════════════
    Rectangle {
        anchors.fill: parent
        visible: root.showCsv
        color: "#80000000"
        z: 10

        Rectangle {
            width: Math.min(640, parent.width - 48)
            height: Math.min(parent.height - 48, csvCard.implicitHeight + 2 * Theme.spacing.large)
            anchors.centerIn: parent
            radius: Theme.spacing.radiusMedium
            color: Theme.palette.surfaceRaised
            border.color: Theme.palette.border
            border.width: 1

            ColumnLayout {
                id: csvCard
                width: parent.width - 2 * Theme.spacing.large
                x: Theme.spacing.large
                y: Theme.spacing.large
                spacing: Theme.spacing.small

                LogosText {
                    text: "CSV export"
                    font.pixelSize: Theme.typography.panelTitleText
                    font.weight: Theme.typography.weightBold
                }
                AppArea {
                    Layout.fillWidth: true
                    implicitHeight: 260
                    readOnly: true
                    text: root.csvText
                }
                RowLayout {
                    spacing: Theme.spacing.tiny
                    Item { Layout.fillWidth: true }
                    LogosButton {
                        implicitHeight: 36
                        text: "Copy CSV"
                        onClicked: { clip.text = root.csvText; clip.select(); clip.copy(); root.toast("CSV copied"); }
                    }
                    LogosButton {
                        implicitHeight: 36
                        text: "Close"
                        onClicked: root.showCsv = false
                    }
                }
            }
        }
    }

    // ══ TOAST ══════════════════════════════════════════════════════════════════
    Rectangle {
        visible: !!root.toastMsg
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: Theme.spacing.large
        width: Math.min(480, root.width - 32)
        implicitHeight: toastText.implicitHeight + 2 * Theme.spacing.small
        radius: Theme.spacing.radiusPill
        color: Theme.palette.surfaceRaised
        border.color: Theme.palette.border
        border.width: 1
        z: 20
        LogosText {
            id: toastText
            anchors.centerIn: parent
            width: parent.width - 2 * Theme.spacing.medium
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
            text: root.toastMsg
            font.pixelSize: Theme.typography.secondaryText
        }
    }
}
