import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
// The host requires these imports for custom colours to apply (see 3b9640d);
// the view itself styles with its own palette below.
import Logos.Theme
import Logos.Controls

// WhisperBox - pure-QML view over whisperbox_core (no C++ backend).
// Contract with the core (whisperbox_core_impl.h):
//   snapshot()                         -> {identity, deviceId, nodeReady, state{forms,feed,...},
//                                          creatorView, watched, pendingForms, mySubmissions, diagnostics}
//   createForm(defJson)                -> {ok, formId}
//   submitResponse(formId, answersArr) -> {ok}        answers = [{questionId, value}]
//                                          (choice values are option INDICES, checkbox = [idx,...])
//   confirmResponse(formId, address)   closeForm(formId)   exportCsv(formId) -> {ok, csv}
//   shareUri(formId) -> {ok, uri}      shareQr(formId) -> {ok, n, cells}
//   importForm(uriOrId)                resync()   importIdentity(privHex)
// Every form in state.forms carries per-device flags from the core:
//   mine, mySubmitted, myConfirmed, allowed, canRespond.
Item {
    id: root
    anchors.fill: parent

    // ── palette (approved v0.3 indigo/charcoal) ──
    readonly property color wbPrimary: "#7c6ff7"
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
    readonly property color wbSuccessSubtle: "#16301f"
    readonly property color wbWarning: "#fbbf24"
    readonly property color wbWarningSubtle: "#2e2714"
    readonly property color wbError: "#f87171"
    readonly property color wbErrorSubtle: "#341a1d"

    // ── state ──
    property var st: ({})
    property string selectedId: ""
    property string toastMsg: ""
    property bool showCreate: false
    property bool showShare: false
    property bool showCsv: false
    property bool showIdentity: false
    property bool showErrors: false
    property var answers: ({})
    property string shareText: ""
    property var qr: null
    property string csvText: ""
    property string draftTitle: ""
    property string draftDescription: ""
    property var draftQuestions: []
    property bool draftRestrict: false
    property string draftAllowList: ""

    readonly property var qTypes: [
        { t: "text", label: "Short text" }, { t: "textarea", label: "Paragraph" },
        { t: "radioButtons", label: "Single choice" }, { t: "checkbox", label: "Multiple choice" }
    ]

    // ── core plumbing ──
    // The ONLY way this view talks to the core: async (logos.callModuleAsync), never the
    // blocking callModule (a synchronous IPC with a 20 s timeout freezes the whole view).
    // Hosts without the async API get a deferred call so at least the frame paints.
    property int callTimeoutMs: 20000
    function callVia(m, a, cb) {
        var done = function (r) { try { cb(r === undefined || r === null ? "" : String(r)); } catch (e) { console.warn("whisperbox callback", m, e); } };
        if (typeof logos === "undefined" || !logos) { Qt.callLater(function () { done(""); }); return; }
        if (typeof logos.callModuleAsync === "function") {
            try { logos.callModuleAsync("whisperbox_core", m, a || [], done, root.callTimeoutMs); }
            catch (e) { Qt.callLater(function () { done(""); }); }
            return;
        }
        Qt.callLater(function () { var r = ""; try { r = logos.callModule("whisperbox_core", m, a || []); } catch (e) {} done(r); });
    }
    // Host results may arrive JSON-string-wrapped (once or twice) - peel, then parse.
    function parse(raw) {
        var s = String(raw || "").trim();
        for (var i = 0; i < 2 && s.charAt(0) === "\""; i++) { try { s = String(JSON.parse(s)).trim(); } catch (e) { return null; } }
        if (s.charAt(0) !== "{") return null;
        try { return JSON.parse(s); } catch (e) { return null; }
    }
    function applySnapshot(o) { if (o && o.state) root.st = o; }
    // Single-flight snapshot poll: never stack requests on a slow core; a stuck call is
    // abandoned after 45 s so one lost reply can't stop the poll forever.
    property bool refreshBusy: false
    property bool refreshAgain: false
    property double refreshSince: 0
    property int refreshMisses: 0
    function refresh() {
        if (root.refreshBusy && Date.now() - root.refreshSince < 45000) { root.refreshAgain = true; return; }
        root.refreshBusy = true; root.refreshSince = Date.now();
        callVia("snapshot", [], function (raw) {
            var o = parse(raw);
            if (o && o.state) { root.st = o; root.refreshMisses = 0; } else root.refreshMisses++;
            root.refreshBusy = false;
            if (root.refreshAgain) { root.refreshAgain = false; refresh(); }
        });
    }
    // Mutation: call, then refresh and toast the outcome; cb(result) only on success.
    // One in-flight call per action name guards against double taps.
    property var inFlight: ({})
    function act(m, a, okMsg, cb) {
        if (root.inFlight[m]) return;
        var f = Object.assign({}, root.inFlight); f[m] = true; root.inFlight = f;
        callVia(m, a, function (raw) {
            var g = Object.assign({}, root.inFlight); delete g[m]; root.inFlight = g;
            var r = parse(raw);
            refresh();
            if (r && r.ok) { if (okMsg) toast(okMsg); if (cb) cb(r); return; }
            toast(r && r.error ? r.error : (raw === "" ? "WhisperBox core did not answer - is whisperbox_core loaded?" : "Request failed"));
        });
    }
    function busy(m) { return !!root.inFlight[m]; }
    function toast(msg) { root.toastMsg = String(msg); toastTimer.restart(); }
    function copyText(t, what) {
        clip.text = String(t || ""); clip.selectAll(); clip.copy(); clip.deselect();
        toast((what || "Text") + " copied");
    }

    // ── derived ──
    readonly property var forms: (st.state && st.state.forms) ? st.state.forms : ({})
    readonly property var pendingForms: st.pendingForms || []
    readonly property var creatorView: st.creatorView || null
    readonly property var diag: st.diagnostics || ({})
    readonly property string myAddress: (st.identity && st.identity.address) ? st.identity.address : ""
    readonly property bool nodeReady: !!st.nodeReady
    readonly property var sel: forms[selectedId] || null
    readonly property bool selPending: !sel && selectedId !== "" && pendingForms.indexOf(selectedId) >= 0
    readonly property var selResponses: responsesFor(selectedId)
    readonly property int selConfirmed: { var n = 0; for (var i = 0; i < selResponses.length; i++) if (selResponses[i].confirmed) n++; return n; }

    function responsesFor(fid) {
        if (!creatorView || !creatorView.responses || !creatorView.responses[fid]) return [];
        return creatorView.responses[fid];
    }
    // Arrays from the host/model can be sequence wrappers (Array.isArray false).
    function isList(v) { return v !== null && v !== undefined && typeof v === "object" && typeof v.length === "number"; }
    function toList(v) { return isList(v) ? Array.prototype.slice.call(v) : []; }
    function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
    function shortAddr(a) { if (!a) return "-"; return a.length > 14 ? a.substr(0, 6) + "..." + a.substr(-4) : a; }
    function fmtTime(ms) { if (!ms) return ""; return Qt.formatDateTime(new Date(Number(ms)), "d MMM yyyy, hh:mm"); }
    function normType(t) {
        var s = String(t);
        return (s === "text" || s === "textarea" || s === "radioButtons" || s === "checkbox") ? s : "text";
    }
    function questionFor(f, qid) {
        if (!f || !f.questions) return null;
        for (var i = 0; i < f.questions.length; i++) if (f.questions[i].id === qid) return f.questions[i];
        return null;
    }
    // Answer value -> display text (choice values are option indices).
    function answerText(q, v) {
        if (v === null || v === undefined || v === "") return "";
        var opts = (q && q.options) ? q.options : [];
        var one = function (x) { return (typeof x === "number" && opts[x] !== undefined) ? String(opts[x]) : String(x); };
        if (isList(v)) { var parts = []; for (var i = 0; i < v.length; i++) parts.push(one(v[i])); return parts.join(", "); }
        return one(v);
    }

    // Sidebar rows: section headers + form rows, grouped by relationship.
    readonly property var sidebarRows: {
        var mine = [], answered = [], open = [], rows = [];
        var ids = Object.keys(root.forms);
        ids.sort(function (a, b) { return (root.forms[b].createdAt || 0) - (root.forms[a].createdAt || 0); });
        for (var i = 0; i < ids.length; i++) {
            var f = root.forms[ids[i]];
            if (f.mine) mine.push(f.id);
            else if (f.mySubmitted) answered.push(f.id);
            else if (f.status === "open") open.push(f.id);
        }
        var add = function (label, list, kind) {
            if (list.length === 0) return;
            rows.push({ kind: "h", label: label + "  " + list.length });
            for (var k = 0; k < list.length; k++) rows.push({ kind: kind, id: list[k] });
        };
        add("WAITING FOR SYNC", root.pendingForms, "p");
        add("MY FORMS", mine, "f");
        add("ANSWERED", answered, "f");
        add("OPEN FORMS", open, "f");
        return rows;
    }

    // ── actions ──
    function selectForm(id) { root.selectedId = id; root.answers = ({}); root.showErrors = false; }
    function joinForm() {
        var t = String(joinField.text || "").trim();
        if (!t) return;
        var arg = t.indexOf("whisperbox://") === 0 ? t : "whisperbox://form?id=" + t;
        act("importForm", [arg], "", function (r) {
            joinField.text = "";
            selectForm(String(r.formId || "").toLowerCase());
            toast(r.pending ? "Form added - waiting for it to sync" : "Form opened");
        });
    }
    function setAnswer(qid, v) { var a = Object.assign({}, root.answers); a[qid] = v; root.answers = a; }
    function toggleChoice(qid, idx) {
        var cur = toList(root.answers[qid]);
        var at = cur.indexOf(idx);
        if (at >= 0) cur.splice(at, 1); else { cur.push(idx); cur.sort(function (a, b) { return a - b; }); }
        setAnswer(qid, cur);
    }
    function isMissing(q) {
        var v = root.answers[q.id];
        return !!q.required && (v === undefined || v === null || (typeof v === "string" && v.trim() === "") || (isList(v) && v.length === 0));
    }
    function doSubmit() {
        var f = root.sel;
        if (!f || !f.canRespond) return;
        var arr = [];
        for (var i = 0; i < f.questions.length; i++) {
            var q = f.questions[i];
            if (isMissing(q)) { root.showErrors = true; toast("Please answer: " + q.text); return; }
            var v = root.answers[q.id];
            if (v === undefined) v = normType(q.type) === "checkbox" ? [] : (normType(q.type) === "radioButtons" ? null : "");
            arr.push({ questionId: q.id, value: v });
        }
        act("submitResponse", [f.id, JSON.stringify(arr)], "Response sealed and sent", function () {
            root.answers = ({}); root.showErrors = false;
        });
    }
    function confirmResponse(addr) { act("confirmResponse", [root.selectedId, addr], "Receipt sent"); }
    function closeSelected() { act("closeForm", [root.selectedId], "Form closed - no new responses"); }
    function openShare() {
        var id = root.selectedId;
        callVia("shareUri", [id], function (raw) {
            var u = parse(raw);
            if (!u || !u.ok) { toast(u && u.error ? u.error : "Could not build link"); return; }
            root.shareText = u.uri; root.qr = null; root.showShare = true;
            callVia("shareQr", [id], function (rq) {
                var q = parse(rq);
                root.qr = (q && q.ok) ? q : null;
                qrCanvas.requestPaint();
            });
        });
    }
    function openCsv() {
        callVia("exportCsv", [root.selectedId], function (raw) {
            var r = parse(raw);
            if (!r || !r.ok) { toast(r && r.error ? r.error : "Export failed"); return; }
            root.csvText = r.csv; root.showCsv = true;
        });
    }
    function resync() { act("resync", [], "Asked peers for missing forms"); }
    function importKey() {
        var k = String(keyField.text || "").trim().replace(/^0x/, "");
        act("importIdentity", [k], "Identity imported", function () { keyField.text = ""; });
    }

    // ── create-form draft ──
    function openCreate() {
        root.draftTitle = ""; root.draftDescription = ""; root.draftRestrict = false; root.draftAllowList = "";
        root.draftQuestions = [{ type: "text", text: "", required: true, optionsText: "" }];
        root.showCreate = true;
    }
    function addDraftQuestion() { root.draftQuestions = root.draftQuestions.concat([{ type: "text", text: "", required: false, optionsText: "" }]); }
    function removeDraftQuestion(i) { var a = root.draftQuestions.slice(); a.splice(i, 1); root.draftQuestions = a; }
    function setDraft(i, prop, v) { if (i < 0 || i >= root.draftQuestions.length) return; var a = root.draftQuestions.slice(); var q = Object.assign({}, a[i]); q[prop] = v; a[i] = q; root.draftQuestions = a; }
    function draftOptions(q) {
        var out = [], lines = String(q.optionsText || "").split("\n");
        for (var i = 0; i < lines.length; i++) { var s = lines[i].trim(); if (s) out.push(s); }
        return out;
    }
    function doCreate() {
        var title = root.draftTitle.trim();
        if (!title) { toast("Give the form a title"); return; }
        var qs = [];
        for (var i = 0; i < root.draftQuestions.length; i++) {
            var d = root.draftQuestions[i], text = String(d.text || "").trim();
            if (!text) continue;
            var q = { id: "q" + (qs.length + 1), type: d.type, text: text, required: !!d.required };
            if (d.type === "radioButtons" || d.type === "checkbox") {
                q.options = draftOptions(d);
                if (q.options.length < 2) { toast("\"" + text + "\" needs at least two options"); return; }
            }
            qs.push(q);
        }
        if (qs.length === 0) { toast("Add at least one question"); return; }
        var wl = { type: "none", value: "" };
        if (root.draftRestrict) {
            var addrs = root.draftAllowList.split(/[\s,]+/).filter(function (a) { return /^0x[0-9a-fA-F]{40}$/.test(a); });
            if (addrs.length === 0) { toast("Add at least one 0x address, or turn off the restriction"); return; }
            wl = { type: "addresses", value: addrs.join(",").toLowerCase() };
        }
        act("createForm", [JSON.stringify({ title: title, description: root.draftDescription.trim(), questions: qs, whitelist: wl })], "Form published", function (r) {
            root.showCreate = false; selectForm(String(r.formId || "").toLowerCase());
        });
    }

    Timer { interval: 2500; running: true; repeat: true; onTriggered: root.refresh() }
    Timer { id: toastTimer; interval: 3500; onTriggered: root.toastMsg = "" }
    Component.onCompleted: root.refresh()
    Connections {
        target: (typeof logos !== "undefined") ? logos : null
        ignoreUnknownSignals: true
        function onModuleEventReceived(module, event, data) {
            if (module === "whisperbox_core" && event === "stateChanged") root.applySnapshot(root.parse(data));
        }
    }
    // Clipboard bridge (pure QML has no clipboard API; TextEdit.copy() does).
    TextEdit { id: clip; visible: false }

    // ── reusable bits ──
    component WbButton: Rectangle {
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
        color: primary ? (btnMa.containsMouse && active ? "#9187f9" : root.wbPrimary) : (btnMa.containsMouse && active ? root.wbBorder : root.wbSurfaceRaised)
        border.color: primary ? "transparent" : (danger ? root.wbError : root.wbBorder)
        border.width: 1
        Text { textFormat: Text.PlainText;
            id: btnT
            anchors.centerIn: parent
            text: btn.label
            font.pixelSize: 12
            font.weight: Font.DemiBold
            color: btn.primary ? "white" : (btn.danger ? root.wbError : root.wbText)
        }
        MouseArea { id: btnMa; anchors.fill: parent; hoverEnabled: true; cursorShape: btn.active ? Qt.PointingHandCursor : Qt.ArrowCursor; onClicked: if (btn.active) btn.clicked() }
    }
    component Badge: Rectangle {
        property string label: ""
        property color fg: root.wbSuccess
        property color bg: root.wbSuccessSubtle
        implicitWidth: bT.implicitWidth + 14
        implicitHeight: 20
        radius: 10
        color: bg
        Text { textFormat: Text.PlainText; id: bT; anchors.centerIn: parent; text: parent.label; font.pixelSize: 10; font.weight: Font.DemiBold; color: parent.fg }
    }
    component SectionLabel: Text { textFormat: Text.PlainText; font.pixelSize: 10; font.weight: Font.DemiBold; font.letterSpacing: 0.6; color: root.wbTextTert }
    component LockIcon: Item {
        property color tint: root.wbPrimary
        implicitWidth: 16; implicitHeight: 19
        Rectangle { x: 3; y: 0; width: 10; height: 12; radius: 5; color: "transparent"; border.color: parent.tint; border.width: 2 }
        Rectangle { x: 0; y: 7; width: 16; height: 12; radius: 3; color: parent.tint }
        Rectangle { x: 7; y: 11; width: 2; height: 4; radius: 1; color: root.wbBg }
    }
    component FormGlyph: Rectangle {
        implicitWidth: 32; implicitHeight: 32; radius: 8; color: root.wbPrimarySubtle
        Column {
            anchors.centerIn: parent; spacing: 3
            Rectangle { width: 14; height: 2; radius: 1; color: root.wbPrimary }
            Rectangle { width: 10; height: 2; radius: 1; color: root.wbPrimary }
            Rectangle { width: 12; height: 2; radius: 1; color: root.wbPrimary }
        }
    }
    component InputBox: Rectangle {
        property bool invalid: false
        radius: 10
        color: root.wbSurfaceRaised
        border.color: invalid ? root.wbError : root.wbBorder
        border.width: 1
    }

    RowLayout {
        anchors.fill: parent
        spacing: 0

        // ══ SIDEBAR ══
        Rectangle {
            Layout.preferredWidth: 300
            Layout.fillHeight: true
            color: root.wbBg

            Rectangle { anchors.right: parent.right; width: 1; height: parent.height; color: root.wbBorderSubtle }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: 16
                spacing: 12

                RowLayout {
                    spacing: 10
                    LockIcon {}
                    ColumnLayout {
                        spacing: 0
                        Text { textFormat: Text.PlainText; text: "WhisperBox"; font.pixelSize: 16; font.weight: Font.Bold; color: root.wbText }
                        Text { textFormat: Text.PlainText; text: "end-to-end encrypted forms"; font.pixelSize: 11; color: root.wbTextTert }
                    }
                }

                WbButton { Layout.fillWidth: true; implicitHeight: 40; primary: true; label: "+ New form"; onClicked: root.openCreate() }

                SectionLabel { text: "OPEN A SHARED FORM" }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 6
                    InputBox {
                        Layout.fillWidth: true
                        implicitHeight: 36
                        TextField {
                            id: joinField
                            anchors.fill: parent
                            anchors.leftMargin: 10
                            anchors.rightMargin: 10
                            color: root.wbText
                            placeholderTextColor: root.wbTextTert
                            font.pixelSize: 12
                            background: null
                            placeholderText: "whisperbox:// link or form id"
                            onAccepted: root.joinForm()
                        }
                    }
                    WbButton { label: "Open"; active: String(joinField.text || "").trim().length > 0; onClicked: root.joinForm() }
                }

                ListView {
                    id: formList
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                    clip: true
                    spacing: 4
                    model: root.sidebarRows
                    boundsBehavior: Flickable.StopAtBounds
                    delegate: Item {
                        id: row
                        width: formList.width
                        height: modelData.kind === "h" ? 30 : 54
                        property var f: modelData.kind === "f" ? root.forms[modelData.id] : null
                        property bool current: modelData.kind !== "h" && modelData.id === root.selectedId

                        SectionLabel {
                            visible: modelData.kind === "h"
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 6
                            text: modelData.kind === "h" ? modelData.label : ""
                        }
                        Rectangle {
                            visible: modelData.kind !== "h"
                            anchors.fill: parent
                            radius: 10
                            color: row.current ? root.wbPrimarySubtle : (rowMa.containsMouse ? root.wbSurface : "transparent")
                            border.color: row.current ? root.wbPrimary : "transparent"
                            border.width: 1
                            RowLayout {
                                anchors.fill: parent
                                anchors.leftMargin: 10
                                anchors.rightMargin: 10
                                spacing: 10
                                FormGlyph { opacity: row.f && row.f.status === "closed" ? 0.5 : 1 }
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 1
                                    Text { textFormat: Text.PlainText;
                                        Layout.fillWidth: true
                                        text: row.f ? (row.f.title || "(untitled)") : (modelData.id || "")
                                        font.pixelSize: 13
                                        font.weight: Font.DemiBold
                                        color: root.wbText
                                        elide: Text.ElideRight
                                    }
                                    Text { textFormat: Text.PlainText;
                                        Layout.fillWidth: true
                                        elide: Text.ElideRight
                                        font.pixelSize: 11
                                        color: root.wbTextTert
                                        text: {
                                            if (!row.f) return "syncing...";
                                            var parts = [root.plural(row.f.questions.length, "question", "questions")];
                                            if (row.f.mine) parts.push(root.plural(root.responsesFor(row.f.id).length, "response", "responses"));
                                            if (row.f.status === "closed") parts.push("closed");
                                            return parts.join("  ·  ");
                                        }
                                    }
                                }
                                Badge {
                                    visible: !!(row.f && !row.f.mine && row.f.mySubmitted)
                                    label: row.f && row.f.myConfirmed ? "Confirmed" : "Sent"
                                    fg: row.f && row.f.myConfirmed ? root.wbSuccess : root.wbTextSec
                                    bg: row.f && row.f.myConfirmed ? root.wbSuccessSubtle : root.wbSurfaceRaised
                                }
                            }
                            MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.selectForm(modelData.id) }
                        }
                    }
                    Text { textFormat: Text.PlainText;
                        visible: root.sidebarRows.length === 0
                        anchors.centerIn: parent
                        width: parent.width - 20
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        text: root.nodeReady ? "No forms yet. Create one, or open a link someone shared with you." : "Connecting to the network..."
                        font.pixelSize: 12
                        color: root.wbTextTert
                    }
                }

                Rectangle { Layout.fillWidth: true; height: 1; color: root.wbBorderSubtle }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: 40
                    radius: 10
                    color: footMa.containsMouse ? root.wbSurface : "transparent"
                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 8
                        anchors.rightMargin: 8
                        spacing: 8
                        Rectangle { width: 8; height: 8; radius: 4; color: root.refreshMisses >= 3 ? root.wbError : (root.nodeReady ? root.wbSuccess : root.wbWarning) }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 0
                            Text { textFormat: Text.PlainText; text: root.refreshMisses >= 3 ? "Can't reach the WhisperBox core" : (root.nodeReady ? "Connected" : "Connecting..."); font.pixelSize: 11; font.weight: Font.DemiBold; color: root.refreshMisses >= 3 ? root.wbError : root.wbTextSec }
                            Text { textFormat: Text.PlainText; text: "You: " + root.shortAddr(root.myAddress); font.pixelSize: 11; font.family: "monospace"; color: root.wbTextTert }
                        }
                        Text { textFormat: Text.PlainText; text: "Identity"; font.pixelSize: 11; color: root.wbPrimary }
                    }
                    MouseArea { id: footMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor; onClicked: root.showIdentity = true }
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
                visible: !root.sel && !root.selPending
                anchors.centerIn: parent
                width: Math.min(420, parent.width - 48)
                spacing: 10
                LockIcon { Layout.alignment: Qt.AlignHCenter; tint: root.wbTextTert }
                Text { textFormat: Text.PlainText; Layout.alignment: Qt.AlignHCenter; text: "Select a form"; font.pixelSize: 18; font.weight: Font.DemiBold; color: root.wbTextSec }
                Text { textFormat: Text.PlainText;
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: "Forms are public; answers are sealed so that only the form's creator can read them."
                    font.pixelSize: 13
                    color: root.wbTextTert
                }
            }

            // Imported link whose definition hasn't synced yet
            ColumnLayout {
                visible: root.selPending
                anchors.centerIn: parent
                width: Math.min(440, parent.width - 48)
                spacing: 12
                Text { textFormat: Text.PlainText; Layout.alignment: Qt.AlignHCenter; text: "Waiting for the form to sync"; font.pixelSize: 18; font.weight: Font.DemiBold; color: root.wbTextSec }
                Text { textFormat: Text.PlainText;
                    Layout.fillWidth: true
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    text: "The link only carries the form id (" + root.selectedId + "). Its questions arrive from peers on the network - usually within seconds of connecting."
                    font.pixelSize: 13
                    color: root.wbTextTert
                }
                WbButton { Layout.alignment: Qt.AlignHCenter; label: "Ask peers again"; onClicked: root.resync() }
            }

            Flickable {
                id: detailFlick
                visible: !!root.sel
                anchors.fill: parent
                anchors.margins: 28
                contentWidth: width
                contentHeight: detailCol.implicitHeight + 40
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                ColumnLayout {
                    id: detailCol
                    width: Math.min(detailFlick.width - 12, 860)
                    spacing: 16

                    // ── header ──
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 12
                        Text { textFormat: Text.PlainText;
                            Layout.fillWidth: true
                            text: root.sel ? (root.sel.title || "(untitled)") : ""
                            font.pixelSize: 24
                            font.weight: Font.Bold
                            color: root.wbText
                            wrapMode: Text.WordWrap
                        }
                        WbButton { visible: !!root.sel; label: "Share"; onClicked: root.openShare() }
                    }
                    Flow {
                        Layout.fillWidth: true
                        spacing: 8
                        Badge {
                            label: root.sel && root.sel.status === "closed" ? "Closed" : "Open"
                            fg: root.sel && root.sel.status === "closed" ? root.wbTextSec : root.wbSuccess
                            bg: root.sel && root.sel.status === "closed" ? root.wbSurfaceRaised : root.wbSuccessSubtle
                        }
                        Badge { visible: !!(root.sel && root.sel.mine); label: "Yours"; fg: root.wbPrimary; bg: root.wbPrimarySubtle }
                        Badge {
                            visible: !!(root.sel && root.sel.whitelist && root.sel.whitelist.type === "addresses")
                            label: "Members only"; fg: root.wbAccent; bg: root.wbWarningSubtle
                        }
                        Badge { visible: !!(root.sel && root.sel.contested); label: "Contested id"; fg: root.wbWarning; bg: root.wbWarningSubtle }
                        Text { textFormat: Text.PlainText;
                            height: 20
                            verticalAlignment: Text.AlignVCenter
                            text: root.sel ? "by " + root.shortAddr(root.sel.creator) + (root.sel.createdAt ? "  ·  " + root.fmtTime(root.sel.createdAt) : "") : ""
                            font.pixelSize: 12
                            color: root.wbTextTert
                        }
                    }
                    Text { textFormat: Text.PlainText;
                        Layout.fillWidth: true
                        visible: !!(root.sel && root.sel.description)
                        text: root.sel ? (root.sel.description || "") : ""
                        font.pixelSize: 14
                        color: root.wbTextSec
                        wrapMode: Text.WordWrap
                    }

                    // ══ CREATOR VIEW ══
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: !!(root.sel && root.sel.mine)
                        spacing: 16

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 12
                            Repeater {
                                model: [
                                    { n: root.selResponses.length, l: "Responses", c: root.wbPrimary },
                                    { n: root.selConfirmed, l: "Receipts sent", c: root.wbSuccess },
                                    { n: root.selResponses.length - root.selConfirmed, l: "Awaiting receipt", c: root.wbWarning }
                                ]
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: 76
                                    radius: 12
                                    color: root.wbSurfaceRaised
                                    ColumnLayout {
                                        anchors.centerIn: parent
                                        spacing: 2
                                        Text { textFormat: Text.PlainText; Layout.alignment: Qt.AlignHCenter; text: String(modelData.n); font.pixelSize: 28; font.weight: Font.Bold; color: modelData.c }
                                        Text { textFormat: Text.PlainText; Layout.alignment: Qt.AlignHCenter; text: modelData.l; font.pixelSize: 11; color: root.wbTextTert }
                                    }
                                }
                            }
                        }

                        RowLayout {
                            spacing: 8
                            WbButton { label: "Export CSV"; active: root.selResponses.length > 0; onClicked: root.openCsv() }
                            WbButton {
                                visible: !!(root.sel && root.sel.status === "open")
                                label: "Close form"
                                danger: true
                                onClicked: root.closeSelected()
                            }
                        }

                        SectionLabel { text: "RESPONSES (" + root.selResponses.length + ")" }
                        Text { textFormat: Text.PlainText;
                            visible: root.selResponses.length === 0
                            Layout.fillWidth: true
                            wrapMode: Text.WordWrap
                            text: "No responses yet. Share the link - answers arrive sealed and only this device can open them."
                            font.pixelSize: 13
                            color: root.wbTextTert
                        }

                        Repeater {
                            model: root.selResponses
                            Rectangle {
                                id: respCard
                                Layout.fillWidth: true
                                implicitHeight: respCol.implicitHeight + 28
                                radius: 12
                                color: root.wbSurfaceRaised
                                border.color: root.wbBorderSubtle
                                border.width: 1
                                property var resp: modelData

                                ColumnLayout {
                                    id: respCol
                                    anchors.left: parent.left
                                    anchors.right: parent.right
                                    anchors.top: parent.top
                                    anchors.margins: 14
                                    spacing: 10

                                    RowLayout {
                                        Layout.fillWidth: true
                                        spacing: 8
                                        Text { textFormat: Text.PlainText;
                                            text: root.shortAddr(respCard.resp.respondent)
                                            font.pixelSize: 12
                                            font.family: "monospace"
                                            color: root.wbTextSec
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.copyText(respCard.resp.respondent, "Address") }
                                        }
                                        Text { textFormat: Text.PlainText; text: root.fmtTime(respCard.resp.submittedAt); font.pixelSize: 11; color: root.wbTextTert }
                                        Item { Layout.fillWidth: true }
                                        Badge { visible: !!respCard.resp.confirmed; label: "Receipt sent" }
                                        WbButton {
                                            visible: !respCard.resp.confirmed
                                            implicitHeight: 28
                                            label: "Send receipt"
                                            onClicked: root.confirmResponse(respCard.resp.respondent)
                                        }
                                    }
                                    Repeater {
                                        model: respCard.resp.answers || []
                                        ColumnLayout {
                                            Layout.fillWidth: true
                                            spacing: 2
                                            property var q: root.questionFor(root.sel, modelData.questionId)
                                            Text { textFormat: Text.PlainText;
                                                Layout.fillWidth: true
                                                text: parent.q ? parent.q.text : modelData.questionId
                                                font.pixelSize: 11
                                                color: root.wbTextTert
                                                wrapMode: Text.WordWrap
                                            }
                                            Text { textFormat: Text.PlainText;
                                                Layout.fillWidth: true
                                                property string v: root.answerText(parent.q, modelData.value)
                                                text: v.length ? v : "(no answer)"
                                                font.pixelSize: 13
                                                color: v.length ? root.wbText : root.wbTextTert
                                                wrapMode: Text.WordWrap
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }

                    // ══ RESPONDENT VIEW ══
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: !!(root.sel && !root.sel.mine)
                        spacing: 14

                        // status banner (submitted / confirmed / closed / not allowed)
                        Rectangle {
                            Layout.fillWidth: true
                            visible: !!(root.sel && !root.sel.canRespond)
                            implicitHeight: bannerT.implicitHeight + 26
                            radius: 12
                            property bool good: !!(root.sel && root.sel.mySubmitted)
                            property bool danger: !!(root.sel && (root.sel.linkMismatch || (root.sel.contested && root.sel.pinnedCreator !== root.sel.creator)))
                            color: danger ? root.wbErrorSubtle : (good ? root.wbSuccessSubtle : root.wbSurfaceRaised)
                            border.color: danger ? root.wbError : (good ? "#2a4d3a" : root.wbBorder)
                            border.width: 1
                            Text { textFormat: Text.PlainText;
                                id: bannerT
                                anchors.fill: parent
                                anchors.margins: 13
                                wrapMode: Text.WordWrap
                                font.pixelSize: 13
                                color: parent.danger ? root.wbError : (parent.good ? root.wbSuccess : root.wbTextSec)
                                text: {
                                    var f = root.sel;
                                    if (!f) return "";
                                    if (f.linkMismatch) return "This form's creator (" + root.shortAddr(f.creator) + ") is not the one in the link you opened (" + root.shortAddr(f.pinnedCreator) + "). WhisperBox won't send your answers to it.";
                                    if (f.contested && f.pinnedCreator !== f.creator) return "Two different people published a form with this id. Open it from the creator's own link to answer - answers are only ever sealed to the creator that link names.";
                                    if (f.mySubmitted && f.myConfirmed) return "Your answers were received - the creator sent you a receipt.";
                                    if (f.mySubmitted) return "Your answers are sealed and sent. You'll see a receipt here once the creator opens them.";
                                    if (f.status === "closed") return "This form is closed and no longer accepts answers.";
                                    if (!f.allowed) return "This form only accepts answers from specific addresses, and yours (" + root.shortAddr(root.myAddress) + ") isn't on the list.";
                                    if (!f.publicKey) return "Still syncing this form...";
                                    return "";
                                }
                            }
                        }

                        Repeater {
                            model: (root.sel && root.sel.canRespond) ? root.sel.questions : []
                            ColumnLayout {
                                id: qBlock
                                Layout.fillWidth: true
                                spacing: 8
                                property var q: modelData
                                property string qt: root.normType(modelData.type)
                                property bool invalid: root.showErrors && root.isMissing(modelData)

                                Text { textFormat: Text.PlainText;
                                    Layout.fillWidth: true
                                    text: (index + 1) + ". " + qBlock.q.text + (qBlock.q.required ? "  *" : "")
                                    wrapMode: Text.WordWrap
                                    font.pixelSize: 14
                                    font.weight: Font.DemiBold
                                    color: qBlock.invalid ? root.wbError : root.wbText
                                }
                                InputBox {
                                    visible: qBlock.qt === "text"
                                    Layout.fillWidth: true
                                    implicitHeight: 42
                                    invalid: qBlock.invalid
                                    TextField {
                                        anchors.fill: parent
                                        anchors.leftMargin: 12
                                        anchors.rightMargin: 12
                                        color: root.wbText
                                        placeholderTextColor: root.wbTextTert
                                        font.pixelSize: 13
                                        background: null
                                        placeholderText: "Your answer"
                                        onTextChanged: root.setAnswer(qBlock.q.id, text)
                                    }
                                }
                                InputBox {
                                    visible: qBlock.qt === "textarea"
                                    Layout.fillWidth: true
                                    implicitHeight: 104
                                    invalid: qBlock.invalid
                                    ScrollView {
                                        anchors.fill: parent
                                        anchors.margins: 4
                                        TextArea {
                                            color: root.wbText
                                            placeholderTextColor: root.wbTextTert
                                            font.pixelSize: 13
                                            wrapMode: TextEdit.Wrap
                                            background: null
                                            placeholderText: "Your answer"
                                            onTextChanged: root.setAnswer(qBlock.q.id, text)
                                        }
                                    }
                                }
                                Repeater {
                                    model: (qBlock.qt === "radioButtons" || qBlock.qt === "checkbox") ? (qBlock.q.options || []) : []
                                    Rectangle {
                                        id: opt
                                        Layout.fillWidth: true
                                        implicitHeight: 40
                                        radius: 10
                                        property bool multi: qBlock.qt === "checkbox"
                                        property bool on: multi ? root.toList(root.answers[qBlock.q.id]).indexOf(index) >= 0
                                                                : root.answers[qBlock.q.id] === index
                                        color: on ? root.wbPrimarySubtle : (optMa.containsMouse ? root.wbBorderSubtle : root.wbSurfaceRaised)
                                        border.color: on ? root.wbPrimary : (qBlock.invalid ? root.wbError : root.wbBorder)
                                        border.width: 1
                                        RowLayout {
                                            anchors.fill: parent
                                            anchors.leftMargin: 12
                                            anchors.rightMargin: 12
                                            spacing: 10
                                            Rectangle {
                                                width: 16; height: 16
                                                radius: opt.multi ? 4 : 8
                                                color: "transparent"
                                                border.color: opt.on ? root.wbPrimary : root.wbTextTert
                                                border.width: 2
                                                Rectangle { anchors.centerIn: parent; width: 8; height: 8; radius: opt.multi ? 2 : 4; color: root.wbPrimary; visible: opt.on }
                                            }
                                            Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: String(modelData); font.pixelSize: 13; color: root.wbText; elide: Text.ElideRight }
                                        }
                                        MouseArea {
                                            id: optMa
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: opt.multi ? root.toggleChoice(qBlock.q.id, index) : root.setAnswer(qBlock.q.id, index)
                                        }
                                    }
                                }
                            }
                        }

                        WbButton {
                            visible: !!(root.sel && root.sel.canRespond)
                            Layout.fillWidth: true
                            implicitHeight: 46
                            primary: true
                            label: root.busy("submitResponse") ? "Sealing..." : "Seal and send answers"
                            active: !root.busy("submitResponse")
                            onClicked: root.doSubmit()
                        }

                        Rectangle {
                            Layout.fillWidth: true
                            implicitHeight: privRow.implicitHeight + 24
                            radius: 12
                            color: "#141c18"
                            border.color: "#24392d"
                            border.width: 1
                            RowLayout {
                                id: privRow
                                anchors.fill: parent
                                anchors.margins: 12
                                spacing: 10
                                LockIcon { tint: root.wbSuccess; Layout.alignment: Qt.AlignTop }
                                Text { textFormat: Text.PlainText;
                                    Layout.fillWidth: true
                                    text: "Answers are encrypted to the creator's key before they leave this device. Everyone else on the network - including peers that relay and store them - sees only an opaque blob. The receipt the creator sends back can't be linked to your address."
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
    }

    // ══ OVERLAYS ══
    // Shared scrim: click outside a dialog to dismiss.
    Rectangle {
        anchors.fill: parent
        visible: root.showCreate || root.showShare || root.showCsv || root.showIdentity
        color: "#cc07070b"
        z: 10
        MouseArea { anchors.fill: parent; onClicked: { root.showShare = false; root.showCsv = false; root.showIdentity = false; } }
    }

    // ── Share ──
    Rectangle {
        visible: root.showShare
        z: 11
        anchors.centerIn: parent
        width: Math.min(460, root.width - 48)
        height: shareCol.implicitHeight + 48
        radius: 16
        color: root.wbSurface
        border.color: root.wbBorder
        border.width: 1
        MouseArea { anchors.fill: parent }
        ColumnLayout {
            id: shareCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 24
            spacing: 14
            Text { textFormat: Text.PlainText; text: "Share form"; font.pixelSize: 20; font.weight: Font.Bold; color: root.wbText }
            Rectangle {
                Layout.alignment: Qt.AlignHCenter
                width: 196; height: 196
                radius: 12
                color: "white"
                visible: !!root.qr
                Canvas {
                    id: qrCanvas
                    anchors.fill: parent
                    anchors.margins: 14
                    onPaint: {
                        var ctx = getContext("2d");
                        ctx.reset();
                        ctx.fillStyle = "white"; ctx.fillRect(0, 0, width, height);
                        if (!root.qr || !root.qr.cells) return;
                        var n = root.qr.n, s = Math.floor(Math.min(width, height) / n), off = Math.floor((Math.min(width, height) - s * n) / 2);
                        ctx.fillStyle = "#0b0b10";
                        for (var y = 0; y < n; y++)
                            for (var x = 0; x < n; x++)
                                if (root.qr.cells[y * n + x]) ctx.fillRect(off + x * s, off + y * s, s, s);
                    }
                }
            }
            InputBox {
                Layout.fillWidth: true
                implicitHeight: 40
                Text { textFormat: Text.PlainText;
                    anchors.fill: parent
                    anchors.leftMargin: 12
                    anchors.rightMargin: 12
                    verticalAlignment: Text.AlignVCenter
                    text: root.shareText
                    font.pixelSize: 12
                    font.family: "monospace"
                    color: root.wbTextSec
                    elide: Text.ElideMiddle
                }
            }
            Text { textFormat: Text.PlainText;
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 12
                color: root.wbTextTert
                text: "Paste the link into WhisperBox's \"Open a shared form\" box, or scan it with the phone app. The link names the form and its creator, so answers are sealed only to you even if someone copies the form id."
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                WbButton { label: "Close"; onClicked: root.showShare = false }
                WbButton { primary: true; label: "Copy link"; onClicked: root.copyText(root.shareText, "Link") }
            }
        }
    }

    // ── CSV ──
    Rectangle {
        visible: root.showCsv
        z: 11
        anchors.centerIn: parent
        width: Math.min(720, root.width - 48)
        height: Math.min(520, root.height - 48)
        radius: 16
        color: root.wbSurface
        border.color: root.wbBorder
        border.width: 1
        MouseArea { anchors.fill: parent }
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 12
            Text { textFormat: Text.PlainText; text: "Responses as CSV"; font.pixelSize: 20; font.weight: Font.Bold; color: root.wbText }
            Text { textFormat: Text.PlainText;
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 12
                color: root.wbTextTert
                text: "Decrypted on this device only. Copy it into a spreadsheet; nothing is uploaded."
            }
            InputBox {
                Layout.fillWidth: true
                Layout.fillHeight: true
                ScrollView {
                    anchors.fill: parent
                    anchors.margins: 6
                    TextArea {
                        readOnly: true
                        selectByMouse: true
                        text: root.csvText
                        font.pixelSize: 12
                        font.family: "monospace"
                        color: root.wbText
                        wrapMode: TextEdit.NoWrap
                        background: null
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                WbButton { label: "Close"; onClicked: root.showCsv = false }
                WbButton { primary: true; label: "Copy CSV"; onClicked: root.copyText(root.csvText, "CSV") }
            }
        }
    }

    // ── Identity / diagnostics ──
    Rectangle {
        visible: root.showIdentity
        z: 11
        anchors.centerIn: parent
        width: Math.min(560, root.width - 48)
        height: idCol.implicitHeight + 48
        radius: 16
        color: root.wbSurface
        border.color: root.wbBorder
        border.width: 1
        MouseArea { anchors.fill: parent }
        ColumnLayout {
            id: idCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 24
            spacing: 12
            Text { textFormat: Text.PlainText; text: "Identity & network"; font.pixelSize: 20; font.weight: Font.Bold; color: root.wbText }
            SectionLabel { text: "YOUR ADDRESS" }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                InputBox {
                    Layout.fillWidth: true
                    implicitHeight: 38
                    Text { textFormat: Text.PlainText;
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        verticalAlignment: Text.AlignVCenter
                        text: root.myAddress || "-"
                        font.pixelSize: 12
                        font.family: "monospace"
                        color: root.wbText
                        elide: Text.ElideMiddle
                    }
                }
                WbButton { label: "Copy"; onClicked: root.copyText(root.myAddress, "Address") }
            }
            Text { textFormat: Text.PlainText;
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 12
                color: root.wbTextTert
                text: "Creators who restrict a form to specific addresses need this one. It is an Ethereum-style address of this device's key."
            }
            SectionLabel { text: "NETWORK" }
            GridLayout {
                columns: 4
                columnSpacing: 18
                rowSpacing: 4
                Repeater {
                    model: [
                        { k: "Node", v: root.nodeReady ? "connected" : "starting" },
                        { k: "Device", v: st.deviceId || "-" },
                        { k: "Received", v: String(root.diag.rxRaw || 0) },
                        { k: "New events", v: String(root.diag.rxNew || 0) },
                        { k: "Sent", v: String(root.diag.txTotal || 0) },
                        { k: "Dropped", v: String((root.diag.admDropSig || 0) + (root.diag.admDropType || 0)) }
                    ]
                    ColumnLayout {
                        spacing: 0
                        Text { textFormat: Text.PlainText; text: modelData.k; font.pixelSize: 10; color: root.wbTextTert }
                        Text { textFormat: Text.PlainText; text: modelData.v; font.pixelSize: 12; font.family: "monospace"; color: root.wbTextSec }
                    }
                }
            }
            RowLayout {
                spacing: 8
                WbButton { label: "Resync with peers"; active: root.nodeReady; onClicked: root.resync() }
            }
            SectionLabel { text: "USE AN EXISTING KEY" }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                InputBox {
                    Layout.fillWidth: true
                    implicitHeight: 38
                    TextField {
                        id: keyField
                        anchors.fill: parent
                        anchors.leftMargin: 10
                        anchors.rightMargin: 10
                        color: root.wbText
                        placeholderTextColor: root.wbTextTert
                        font.pixelSize: 12
                        font.family: "monospace"
                        echoMode: TextInput.Password
                        background: null
                        placeholderText: "64-hex private key"
                    }
                }
                WbButton { label: "Import"; active: String(keyField.text || "").length >= 64; onClicked: root.importKey() }
            }
            Text { textFormat: Text.PlainText;
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 12
                color: root.wbWarning
                text: "Importing replaces this device's key. Forms you created with the current key can only be decrypted with it - export it first if you need it."
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                WbButton { label: "Done"; onClicked: root.showIdentity = false }
            }
        }
    }

    // ── Create form ──
    Rectangle {
        visible: root.showCreate
        z: 11
        anchors.centerIn: parent
        width: Math.min(640, root.width - 48)
        height: Math.min(root.height - 48, 720)
        radius: 16
        color: root.wbSurface
        border.color: root.wbBorder
        border.width: 1
        MouseArea { anchors.fill: parent }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 22
            spacing: 12

            Text { textFormat: Text.PlainText; text: "New form"; font.pixelSize: 22; font.weight: Font.Bold; color: root.wbText }

            Flickable {
                id: createFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: createCol.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                ColumnLayout {
                    id: createCol
                    width: createFlick.width - 10
                    spacing: 12

                    SectionLabel { text: "TITLE" }
                    InputBox {
                        Layout.fillWidth: true
                        implicitHeight: 42
                        TextField {
                            anchors.fill: parent
                            anchors.leftMargin: 12
                            anchors.rightMargin: 12
                            color: root.wbText
                            placeholderTextColor: root.wbTextTert
                            font.pixelSize: 14
                            font.weight: Font.DemiBold
                            background: null
                            placeholderText: "What are you asking about?"
                            text: root.draftTitle
                            onTextChanged: root.draftTitle = text
                        }
                    }
                    SectionLabel { text: "DESCRIPTION (OPTIONAL)" }
                    InputBox {
                        Layout.fillWidth: true
                        implicitHeight: 64
                        ScrollView {
                            anchors.fill: parent
                            anchors.margins: 4
                            TextArea {
                                color: root.wbText
                                placeholderTextColor: root.wbTextTert
                                font.pixelSize: 13
                                wrapMode: TextEdit.Wrap
                                background: null
                                placeholderText: "Context for respondents"
                                text: root.draftDescription
                                onTextChanged: root.draftDescription = text
                            }
                        }
                    }

                    SectionLabel { text: "QUESTIONS (" + root.draftQuestions.length + ")" }
                    Repeater {
                        model: root.draftQuestions.length
                        Rectangle {
                            id: dq
                            Layout.fillWidth: true
                            implicitHeight: dqCol.implicitHeight + 24
                            radius: 12
                            color: root.wbSurfaceRaised
                            border.color: root.wbBorder
                            border.width: 1
                            // The question's index, captured here: inside the nested type-chip
                            // Repeater below, a bare `index` is the CHIP's index, not the question's.
                            readonly property int qi: index
                            property var d: root.draftQuestions[index] || ({})
                            property bool choice: d.type === "radioButtons" || d.type === "checkbox"

                            ColumnLayout {
                                id: dqCol
                                anchors.left: parent.left
                                anchors.right: parent.right
                                anchors.top: parent.top
                                anchors.margins: 12
                                spacing: 8
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    Text { textFormat: Text.PlainText; text: "Q" + (index + 1); font.pixelSize: 12; font.weight: Font.Bold; color: root.wbPrimary }
                                    InputBox {
                                        Layout.fillWidth: true
                                        implicitHeight: 36
                                        color: root.wbSurface
                                        TextField {
                                            anchors.fill: parent
                                            anchors.leftMargin: 10
                                            anchors.rightMargin: 10
                                            color: root.wbText
                                            placeholderTextColor: root.wbTextTert
                                            font.pixelSize: 13
                                            background: null
                                            placeholderText: "Question"
                                            text: String(dq.d.text || "")
                                            onTextChanged: if (text !== String(dq.d.text || "")) root.setDraft(dq.qi, "text", text)
                                        }
                                    }
                                    Text { textFormat: Text.PlainText;
                                        text: "Remove"
                                        visible: root.draftQuestions.length > 1
                                        font.pixelSize: 11
                                        color: root.wbTextTert
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.removeDraftQuestion(dq.qi) }
                                    }
                                }
                                Flow {
                                    Layout.fillWidth: true
                                    spacing: 6
                                    Repeater {
                                        model: root.qTypes
                                        Rectangle {
                                            property bool on: dq.d.type === modelData.t
                                            implicitWidth: chipT.implicitWidth + 18
                                            implicitHeight: 26
                                            radius: 13
                                            color: on ? root.wbPrimarySubtle : "transparent"
                                            border.color: on ? root.wbPrimary : root.wbBorder
                                            border.width: 1
                                            Text { textFormat: Text.PlainText; id: chipT; anchors.centerIn: parent; text: modelData.label; font.pixelSize: 11; color: parent.on ? root.wbPrimary : root.wbTextSec }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setDraft(dq.qi, "type", modelData.t) }
                                        }
                                    }
                                    Rectangle {
                                        implicitWidth: reqT.implicitWidth + 18
                                        implicitHeight: 26
                                        radius: 13
                                        color: dq.d.required ? root.wbWarningSubtle : "transparent"
                                        border.color: dq.d.required ? root.wbAccent : root.wbBorder
                                        border.width: 1
                                        Text { textFormat: Text.PlainText; id: reqT; anchors.centerIn: parent; text: dq.d.required ? "Required" : "Optional"; font.pixelSize: 11; color: dq.d.required ? root.wbAccent : root.wbTextSec }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setDraft(dq.qi, "required", !dq.d.required) }
                                    }
                                }
                                InputBox {
                                    visible: dq.choice
                                    Layout.fillWidth: true
                                    implicitHeight: 84
                                    color: root.wbSurface
                                    ScrollView {
                                        anchors.fill: parent
                                        anchors.margins: 4
                                        TextArea {
                                            color: root.wbText
                                            placeholderTextColor: root.wbTextTert
                                            font.pixelSize: 12
                                            wrapMode: TextEdit.Wrap
                                            background: null
                                            placeholderText: "One option per line"
                                            text: String(dq.d.optionsText || "")
                                            onTextChanged: if (text !== String(dq.d.optionsText || "")) root.setDraft(dq.qi, "optionsText", text)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    WbButton { Layout.fillWidth: true; label: "+ Add question"; onClicked: root.addDraftQuestion() }

                    SectionLabel { text: "WHO CAN ANSWER" }
                    RowLayout {
                        spacing: 6
                        Repeater {
                            model: [{ r: false, l: "Anyone with the link" }, { r: true, l: "Only listed addresses" }]
                            Rectangle {
                                property bool on: root.draftRestrict === modelData.r
                                implicitWidth: wT.implicitWidth + 22
                                implicitHeight: 30
                                radius: 15
                                color: on ? root.wbPrimarySubtle : "transparent"
                                border.color: on ? root.wbPrimary : root.wbBorder
                                border.width: 1
                                Text { textFormat: Text.PlainText; id: wT; anchors.centerIn: parent; text: modelData.l; font.pixelSize: 12; color: parent.on ? root.wbPrimary : root.wbTextSec }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.draftRestrict = modelData.r }
                            }
                        }
                    }
                    InputBox {
                        visible: root.draftRestrict
                        Layout.fillWidth: true
                        implicitHeight: 76
                        ScrollView {
                            anchors.fill: parent
                            anchors.margins: 4
                            TextArea {
                                color: root.wbText
                                placeholderTextColor: root.wbTextTert
                                font.pixelSize: 12
                                font.family: "monospace"
                                wrapMode: TextEdit.Wrap
                                background: null
                                placeholderText: "0x addresses, one per line (respondents find theirs under Identity)"
                                text: root.draftAllowList
                                onTextChanged: root.draftAllowList = text
                            }
                        }
                    }
                    Text { textFormat: Text.PlainText;
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        font.pixelSize: 12
                        color: root.wbTextTert
                        text: "The form (title, questions, who may answer) is public on the network. Answers are encrypted to your key."
                    }
                }
            }

            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                WbButton { label: "Cancel"; onClicked: root.showCreate = false }
                WbButton { primary: true; label: root.busy("createForm") ? "Publishing..." : "Publish form"; active: !root.busy("createForm"); onClicked: root.doCreate() }
            }
        }
    }

    // ── Toast ──
    Rectangle {
        visible: !!root.toastMsg
        anchors.bottom: parent.bottom
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottomMargin: 24
        width: Math.min(460, root.width - 32)
        implicitHeight: toastT.implicitHeight + 24
        radius: 14
        color: root.wbSurfaceRaised
        border.color: root.wbBorder
        border.width: 1
        z: 20
        Text { textFormat: Text.PlainText;
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
