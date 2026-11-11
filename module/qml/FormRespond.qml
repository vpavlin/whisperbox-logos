// FormRespond.qml - answering one WhisperBox form: the questions, validation, the answer draft,
// submit / edit, the creator's private replies and score. Shared by the studio (module/) and the
// respond module (module-respond/); keep both copies identical (scripts/sync-respond.sh copies,
// the view test checks). ADR 0021.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import "WbPalette.js" as P
import "WbAnswers.js" as WA


// ══ RESPONDENT VIEW ══
ColumnLayout {
    id: fr
    spacing: 14

    // ── the contract with the host view ──
    // form: the selected form, with its private detail merged (myAnswers, myReplies, answerDraft ...)
    property var form: null
    property string myAddress: ""
    property bool preview: false        // the studio's preview of a draft: answers are never sent
    // host: act(method, args, okMsg, cb), callVia(method, args, cb), busy(method), toast(msg)
    property var host: null

    // ── palette (WbPalette.js, the same colours as the studio) ──
    readonly property color wbPrimary: P.wbPrimary
    readonly property color wbPrimarySubtle: P.wbPrimarySubtle
    readonly property color wbAccent: P.wbAccent
    readonly property color wbBg: P.wbBg
    readonly property color wbSurface: P.wbSurface
    readonly property color wbSurfaceRaised: P.wbSurfaceRaised
    readonly property color wbBorder: P.wbBorder
    readonly property color wbBorderSubtle: P.wbBorderSubtle
    readonly property color wbText: P.wbText
    readonly property color wbTextSec: P.wbTextSec
    readonly property color wbTextTert: P.wbTextTert
    readonly property color wbSuccess: P.wbSuccess
    readonly property color wbSuccessSubtle: P.wbSuccessSubtle
    readonly property color wbWarning: P.wbWarning
    readonly property color wbWarningSubtle: P.wbWarningSubtle
    readonly property color wbError: P.wbError
    readonly property color wbErrorSubtle: P.wbErrorSubtle

    // ── answer state (owned here; the studio aliases answers / editing / showErrors) ──
    property var answers: ({})
    property bool editing: false        // editing an already-sent answer
    property bool showErrors: false
    // a draft saved earlier was put back when the form opened (not the one autosaved while typing,
    // which used to flip this note on mid-typing and shift the form under the cursor)
    property bool draftRestored: false
    property double nowTick: Date.now() // refreshes "N min left"
    Timer { interval: 20000; running: true; repeat: true; onTriggered: fr.nowTick = Date.now() }
    Timer { id: answerDraftTimer; interval: 900; onTriggered: fr.saveAnswerDraftNow() }

    // ── shared helpers (WbAnswers.js) ──
    function isList(v) { return WA.isList(v); }
    function toList(v) { return WA.toList(v); }
    function plural(n, one, many) { return WA.plural(n, one, many); }
    function shortAddr(a) { return WA.shortAddr(a); }
    function fmtTime(ms) { return WA.fmtTime(ms); }
    function normType(t) { return WA.normType(t); }
    function answerText(q, v) { return WA.answerText(q, v); }
    function isOtherVal(v) { return WA.isOtherVal(v); }
    function minutesLeft(until) { return Math.max(0, Math.ceil((Number(until) - fr.nowTick) / 60000)); }

    // ── answering ──
    // a new form: forget what was typed for the previous one
    function reset() { answerDraftTimer.stop(); fr.answers = ({}); fr.showErrors = false; fr.editing = false; fr.draftRestored = false; }
    // leaving a form: save the half-filled answers now
    function flushDraft() { if (answerDraftTimer.running) { answerDraftTimer.stop(); saveAnswerDraftNow(); } }
    // cancelling a form: forget the half-filled answers here and in the core
    function discardDraft() {
        answerDraftTimer.stop();
        if (fr.form && fr.form.id && !fr.preview) fr.host.callVia("saveAnswerDraft", [fr.form.id, "[]"], function () {});
        fr.reset();
    }
    // Half-filled answers saved while typing come back (crash, restart, switching forms).
    function restoreAnswerDraft() {
        var f = fr.form, a = {};
        if (f && f.answerDraft && !f.mySubmitted) for (var i = 0; i < f.answerDraft.length; i++) a[f.answerDraft[i].questionId] = f.answerDraft[i].value;
        // the draft arrives with formDetail, after the form is selected: keep anything typed meanwhile
        for (var k in fr.answers) if (fr.answers.hasOwnProperty(k) && fr.answers[k] !== undefined) return;
        fr.answers = a;
        fr.draftRestored = Object.keys(a).length > 0;
    }
    function setAnswer(qid, v) { var a = Object.assign({}, fr.answers); a[qid] = v; fr.answers = a; answerDraftTimer.restart(); }
    function saveAnswerDraftNow() {
        if (fr.preview || !fr.form || fr.form.mine || fr.form.mySubmitted || !fr.host) return;
        var arr = [];
        for (var k in fr.answers) if (fr.answers.hasOwnProperty(k)) arr.push({ questionId: k, value: fr.answers[k] });
        fr.host.callVia("saveAnswerDraft", [fr.form.id, JSON.stringify(arr)], function () {});
    }
    function toggleChoice(qid, idx) {
        var cur = toList(fr.answers[qid]);
        var at = cur.indexOf(idx);
        if (at >= 0) cur.splice(at, 1); else { cur.push(idx); cur.sort(function (a, b) { return a - b; }); }
        setAnswer(qid, cur);
    }
    function problemOf(q) { return WA.validateVal(q, fr.answers[q.id]); }
    readonly property var shownQuestions: {
        var f = fr.form; if (!f || !f.questions) return [];
        if (!f.shuffleQuestions) return f.questions;
        var o = WA.seededOrder(f.questions.length, fr.myAddress + "|" + f.id), out = [];
        for (var i = 0; i < o.length; i++) out.push(f.questions[o[i]]);
        return out;
    }
    function optionOrder(q) {   // indices of q.options in display order
        var n = (q.options || []).length;
        if (!q.shuffleOptions) { var a = []; for (var i = 0; i < n; i++) a.push(i); return a; }
        return WA.seededOrder(n, fr.myAddress + "|" + (fr.form ? fr.form.id : "") + "|" + q.id);
    }
    readonly property var progress: {
        var qs = fr.shownQuestions, n = 0, done = 0;
        for (var i = 0; i < qs.length; i++) { if (normType(qs[i].type) === "section") continue; n++; if (!WA.emptyVal(fr.answers[qs[i].id])) done++; }
        return { n: n, done: done };
    }
    function isMissing(q) {
        var v = fr.answers[q.id];
        return !!q.required && (v === undefined || v === null || (typeof v === "string" && v.trim() === "") || (isList(v) && v.length === 0));
    }
    function startEditing() {
        var f = fr.form; if (!f || !f.myAnswers) return;
        var a = {}; var l = f.myAnswers.answers || [];
        for (var i = 0; i < l.length; i++) a[l[i].questionId] = l[i].value;
        fr.answers = a; fr.showErrors = false; fr.editing = true;
    }
    function doSubmit() {
        var f = fr.form;
        if (fr.preview) { fr.host.toast("This is a preview - answers aren't sent"); return; }
        if (!f || !(f.canRespond || (fr.editing && f.canEdit))) return;
        for (var pi = 0; pi < f.questions.length; pi++) {
            var pq = f.questions[pi], pe = problemOf(pq);
            if (pe) { fr.showErrors = true; fr.host.toast(pq.text + ": " + pe); return; }
        }
        var arr = [];
        for (var i = 0; i < f.questions.length; i++) {
            var q = f.questions[i];
            if (isMissing(q)) { fr.showErrors = true; fr.host.toast("Please answer: " + q.text); return; }
            var v = fr.answers[q.id];
            if (normType(q.type) === "section") continue;
            if (v === undefined) { var tt = normType(q.type); v = tt === "checkbox" ? [] : ((tt === "text" || tt === "textarea" || tt === "email" || tt === "url") ? "" : null); }
            arr.push({ questionId: q.id, value: v });
        }
        answerDraftTimer.stop();   // the core drops the answer draft on submit
        var wasEditing = fr.editing;
        fr.host.act("submitResponse", [f.id, JSON.stringify(arr)], wasEditing ? "Your edited answer is sealed and sent" : "Response sealed and sent", function () {
            fr.answers = ({}); fr.showErrors = false; fr.editing = false;
        });
    }

    Text { textFormat: Text.PlainText
        Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: fr.wbTextTert
        visible: text.length > 0
        text: {
            var f = fr.form, parts = [];
            if (!f) return "";
            if (f.showResponseCount) parts.push(fr.plural((f.confirmations || []).length, "response", "responses") + " received so far");
            if (f.maxResponses) parts.push("limited to " + f.maxResponses);
            if (f.expiresAt) parts.push((f.status === "closed" ? "closed " : "closes ") + fr.fmtTime(f.expiresAt));
            if (fr.draftRestored && !f.mySubmitted) parts.push("your unsent answers were restored");
            if (f.anonymous) parts.push("anonymous: you answer under a one-off identity for this form - the creator can't link it to your address");
            return parts.join("  ·  ");
        }
    }
    // status banner (submitted / confirmed / closed / not allowed)
    Rectangle {
        Layout.fillWidth: true
        visible: !!(fr.form && !fr.form.canRespond) && bannerT.text.length > 0
        implicitHeight: bannerT.implicitHeight + 26
        radius: 12
        property bool good: !!(fr.form && fr.form.mySubmitted)
        property bool danger: !!(fr.form && (fr.form.linkMismatch || (fr.form.contested && fr.form.pinnedCreator !== fr.form.creator)))
        color: danger ? fr.wbErrorSubtle : (good ? fr.wbSuccessSubtle : fr.wbSurfaceRaised)
        border.color: danger ? fr.wbError : (good ? "#2a4d3a" : fr.wbBorder)
        border.width: 1
        Text { textFormat: Text.PlainText;
            id: bannerT
            anchors.fill: parent
            anchors.margins: 13
            wrapMode: Text.WordWrap
            font.pixelSize: 13
            color: parent.danger ? fr.wbError : (parent.good ? fr.wbSuccess : fr.wbTextSec)
            text: {
                var f = fr.form;
                if (!f) return "";
                if (f.linkMismatch) return "This form's creator (" + fr.shortAddr(f.creator) + ") is not the one in the link you opened (" + fr.shortAddr(f.pinnedCreator) + "). WhisperBox won't send your answers to it. If that link was wrong, Remove the form, then open the right one.";
                if (f.needsLink) return "To answer, open this form from its creator's link or QR code. A bare form id doesn't say who made it, so anyone could publish a form under it, and WhisperBox only sends answers to the creator a link names.";
                if (f.contested && f.pinnedCreator !== f.creator) return "Two different people published a form with this id. Open it from the creator's own link to answer - answers are only ever sealed to the creator that link names.";
                if (f.mySubmitted) return (f.thankYou ? f.thankYou + "\n\n" : "") + (f.myConfirmed
                    ? "Your answers were received - the creator sent you a receipt."
                    : "Your answers are sealed and sent. You'll see a receipt here once the creator opens them.");
                if (f.mine) return "This is your own form - it was created with this Basecamp's address (" + fr.shortAddr(f.creator) + "), and a creator can't answer their own form. Its answers are in the WhisperBox studio. To try it as a respondent, open the link on another device.";
                if (f.status === "closed") return "This form is closed and no longer accepts answers.";
                if (!f.allowed) return "This form only accepts answers from specific addresses, and yours (" + fr.shortAddr(fr.myAddress) + ") isn't on the list.";
                if (!f.publicKey) return "Still syncing this form...";
                return "";
            }
        }
    }
    // private replies + quiz score from the creator (sealed to this answer)
    Rectangle {
        Layout.fillWidth: true
        visible: !!(fr.form && fr.form.myReplies && fr.form.myReplies.length)
        implicitHeight: repCol.implicitHeight + 28
        radius: 12; color: fr.wbPrimarySubtle; border.color: fr.wbPrimary; border.width: 1
        ColumnLayout {
            id: repCol; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14; spacing: 10
            Text { textFormat: Text.PlainText; text: "FROM THE CREATOR - ONLY YOU CAN READ THIS"; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 0.8; color: fr.wbPrimary }
            Repeater {
                model: fr.form && fr.form.myReplies ? fr.form.myReplies : []
                ColumnLayout {
                    Layout.fillWidth: true; spacing: 4
                    Text { textFormat: Text.PlainText; visible: modelData.kind === "score"; text: "Your score: " + modelData.score + " / " + modelData.outOf; font.pixelSize: 18; font.weight: Font.Bold; color: fr.wbText }
                    Text { textFormat: Text.PlainText; visible: modelData.kind === "score"; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: fr.wbTextSec
                        text: {
                            if (modelData.kind !== "score" || !fr.form) return "";
                            var c = modelData.correct || {}, out = [];
                            for (var i = 0; i < fr.form.questions.length; i++) { var q = fr.form.questions[i]; if (q.id in c) out.push((c[q.id] ? "\u2713 " : "\u2717 ") + q.text); }
                            return out.join("\n");
                        } }
                    Text { textFormat: Text.PlainText; visible: !!modelData.message; Layout.fillWidth: true; wrapMode: Text.WordWrap; text: modelData.message || ""; font.pixelSize: 14; color: fr.wbText }
                    Text { textFormat: Text.PlainText; text: modelData.at ? fr.fmtTime(modelData.at) : ""; font.pixelSize: 10; color: fr.wbTextTert }
                }
            }
        }
    }

    // What I answered (a private local copy - the sent answers are sealed to the creator)
    ColumnLayout {
        Layout.fillWidth: true
        visible: !!(fr.form && !fr.form.mine && fr.form.mySubmitted && !fr.editing)
        spacing: 10
        RowLayout {
            Layout.fillWidth: true
            SectionLabel { Layout.fillWidth: true; text: "YOUR ANSWERS" }
            WbButton {
                visible: !!(fr.form && fr.form.canEdit)
                label: "Edit answers (" + fr.minutesLeft(fr.form ? fr.form.editUntil : 0) + " min left)"
                onClicked: fr.startEditing()
            }
        }
        Text { textFormat: Text.PlainText
            visible: !!(fr.form && fr.form.mySubmitted && !fr.form.myAnswers)
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: "Sent from an older WhisperBox that didn't keep a copy. Only the creator can read them now."
            font.pixelSize: 12; color: fr.wbTextTert
        }
        Repeater {
            model: (fr.form && fr.form.myAnswers) ? fr.form.questions : []
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                property var v: {
                    var a = fr.form.myAnswers.answers || [];
                    for (var i = 0; i < a.length; i++) if (a[i].questionId === modelData.id) return a[i].value;
                    return null;
                }
                Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap
                    text: modelData.text; font.pixelSize: 12; color: fr.wbTextTert }
                Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap
                    property string t: fr.answerText(modelData, parent.v)
                    text: t.length ? t : "(no answer)"
                    font.pixelSize: 14; color: t.length ? fr.wbText : fr.wbTextTert }
            }
        }
        Text { textFormat: Text.PlainText
            visible: !!(fr.form && fr.form.myAnswers)
            Layout.fillWidth: true; wrapMode: Text.WordWrap
            text: "Kept only on this device. What went out is sealed - only the creator can open it."
            font.pixelSize: 11; color: fr.wbTextTert
        }
    }

    // progress (longer forms)
    ColumnLayout {
        Layout.fillWidth: true
        visible: !!(fr.form && fr.form.canRespond) && fr.progress.n >= 4
        spacing: 4
        Text { textFormat: Text.PlainText; text: fr.progress.done + " of " + fr.progress.n + " answered"; font.pixelSize: 11; color: fr.wbTextTert }
        Rectangle { Layout.fillWidth: true; implicitHeight: 4; radius: 2; color: fr.wbSurfaceRaised
            Rectangle { height: parent.height; radius: 2; color: fr.wbPrimary; width: parent.width * (fr.progress.n ? fr.progress.done / fr.progress.n : 0) } }
    }

    Repeater {
        model: (fr.form && (fr.form.canRespond || (fr.editing && fr.form.canEdit))) ? fr.shownQuestions : []
        ColumnLayout {
            id: qBlock
            Layout.fillWidth: true
            spacing: 8
            property var q: modelData
            property string qt: fr.normType(modelData.type)
            property string problem: fr.showErrors ? fr.problemOf(modelData) : ""
            property bool invalid: problem.length > 0
            property var cur: fr.answers[modelData.id]
            property bool single: qt === "text" || qt === "email" || qt === "url" || qt === "number" || qt === "date" || qt === "time"
            property bool choice: qt === "radioButtons" || qt === "checkbox" || qt === "dropdown" || qt === "boolean"
            property bool multi: qt === "checkbox"
            property string otherText: fr.isOtherVal(cur) ? String(cur.other) : ""
            function hasOther() {
                if (fr.isOtherVal(cur)) return true;
                var l = fr.toList(cur); for (var i = 0; i < l.length; i++) if (fr.isOtherVal(l[i])) return true; return false;
            }
            function setOther(t, on) {
                if (!multi) { fr.setAnswer(q.id, on ? { other: t } : null); return; }
                var l = fr.toList(cur).filter(function (x) { return !fr.isOtherVal(x); });
                if (on) l.push({ other: t });
                fr.setAnswer(q.id, l);
            }

            Text { textFormat: Text.PlainText
                Layout.fillWidth: true
                text: (qBlock.qt === "section" ? "" : (index + 1) + ". ") + qBlock.q.text + (qBlock.q.required ? "  *" : "")
                wrapMode: Text.WordWrap
                font.pixelSize: qBlock.qt === "section" ? 17 : 14
                font.weight: qBlock.qt === "section" ? Font.Bold : Font.DemiBold
                color: qBlock.invalid ? fr.wbError : fr.wbText
            }
            Text { textFormat: Text.PlainText
                visible: !!qBlock.q.help
                Layout.fillWidth: true; wrapMode: Text.WordWrap
                text: qBlock.q.help || ""; font.pixelSize: 12; color: fr.wbTextTert
            }
            // one-line inputs: text, email, link, number, date, time
            InputBox {
                visible: qBlock.single
                Layout.fillWidth: true
                implicitHeight: 42
                invalid: qBlock.invalid
                TextField {
                    anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12
                    color: fr.wbText; placeholderTextColor: fr.wbTextTert; font.pixelSize: 13; background: null
                    placeholderText: ({ email: "name@example.com", url: "https://...", number: "A number", date: "YYYY-MM-DD", time: "HH:MM" })[qBlock.qt] || "Your answer"
                    inputMethodHints: qBlock.qt === "number" ? Qt.ImhFormattedNumbersOnly : (qBlock.qt === "email" ? Qt.ImhEmailCharactersOnly : Qt.ImhNone)
                    text: qBlock.cur === undefined || qBlock.cur === null ? "" : String(qBlock.cur)
                    onTextChanged: {
                        if (qBlock.qt !== "number") { if (text !== String(qBlock.cur === undefined || qBlock.cur === null ? "" : qBlock.cur)) fr.setAnswer(qBlock.q.id, text); return; }
                        var t = text.trim().replace(",", ".");
                        var v = t === "" ? null : (isNaN(Number(t)) ? t : Number(t));
                        if (v !== qBlock.cur) fr.setAnswer(qBlock.q.id, v);
                    }
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
                        color: fr.wbText; placeholderTextColor: fr.wbTextTert; font.pixelSize: 13
                        wrapMode: TextEdit.Wrap; background: null; placeholderText: "Your answer"
                        text: typeof qBlock.cur === "string" ? qBlock.cur : ""
                        onTextChanged: if (text !== (typeof qBlock.cur === "string" ? qBlock.cur : "")) fr.setAnswer(qBlock.q.id, text)
                    }
                }
            }
            // choices: single / multiple / dropdown (compact) / yes-no
            Flow {
                Layout.fillWidth: true
                spacing: 6
                visible: qBlock.choice
                Repeater {
                    model: qBlock.qt === "boolean" ? [0, 1] : (qBlock.choice ? fr.optionOrder(qBlock.q) : [])
                    Rectangle {
                        id: opt
                        property int oi: modelData
                        property string label: qBlock.qt === "boolean" ? (oi === 0 ? "Yes" : "No") : String((qBlock.q.options || [])[oi])
                        property var val: qBlock.qt === "boolean" ? oi === 0 : oi
                        property bool on: qBlock.multi ? fr.toList(qBlock.cur).indexOf(oi) >= 0 : qBlock.cur === val
                        width: qBlock.qt === "dropdown" ? optLbl.implicitWidth + 28 : qBlock.width
                        height: qBlock.qt === "dropdown" ? 32 : 46
                        radius: qBlock.qt === "dropdown" ? 16 : 10
                        color: on ? fr.wbPrimarySubtle : (optMa.containsMouse ? fr.wbBorderSubtle : fr.wbSurfaceRaised)
                        border.color: on ? fr.wbPrimary : (qBlock.invalid ? fr.wbError : fr.wbBorder)
                        border.width: 1
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; spacing: 10
                            Rectangle {
                                visible: qBlock.qt !== "dropdown"
                                width: 16; height: 16; radius: qBlock.multi ? 4 : 8; color: "transparent"
                                border.color: opt.on ? fr.wbPrimary : fr.wbTextTert; border.width: 2
                                Rectangle { anchors.centerIn: parent; width: 8; height: 8; radius: qBlock.multi ? 2 : 4; color: fr.wbPrimary; visible: opt.on }
                            }
                            Text { id: optLbl; textFormat: Text.PlainText; Layout.fillWidth: qBlock.qt !== "dropdown"; text: opt.label; font.pixelSize: 13; color: opt.on ? fr.wbPrimary : fr.wbText; elide: Text.ElideRight }
                        }
                        MouseArea {
                            id: optMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                            onClicked: qBlock.multi ? fr.toggleChoice(qBlock.q.id, opt.oi) : fr.setAnswer(qBlock.q.id, opt.on && !qBlock.q.required ? null : opt.val)
                        }
                    }
                }
            }
            // "Other: ___"
            RowLayout {
                visible: qBlock.choice && !!qBlock.q.allowOther && qBlock.qt !== "boolean"
                Layout.fillWidth: true
                spacing: 10
                Rectangle {
                    width: 16; height: 16; radius: qBlock.multi ? 4 : 8; color: "transparent"
                    border.color: qBlock.hasOther() ? fr.wbPrimary : fr.wbTextTert; border.width: 2
                    Rectangle { anchors.centerIn: parent; width: 8; height: 8; radius: qBlock.multi ? 2 : 4; color: fr.wbPrimary; visible: qBlock.hasOther() }
                    MouseArea { anchors.fill: parent; anchors.margins: -6; cursorShape: Qt.PointingHandCursor; onClicked: qBlock.setOther(otherField.text, !qBlock.hasOther()) }
                }
                Text { textFormat: Text.PlainText; text: "Other:"; font.pixelSize: 13; color: fr.wbTextSec }
                InputBox { Layout.fillWidth: true; implicitHeight: 36
                    TextField { id: otherField; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                        color: fr.wbText; placeholderTextColor: fr.wbTextTert; font.pixelSize: 13; background: null; placeholderText: "Your own answer"
                        text: qBlock.otherText
                        onTextChanged: if (text !== qBlock.otherText) qBlock.setOther(text, text.trim() !== "") } }
            }
            // linear scale / stars
            ColumnLayout {
                visible: qBlock.qt === "scale"
                Layout.fillWidth: true
                spacing: 4
                property int lo: typeof qBlock.q.min === "number" ? qBlock.q.min : 1
                property int hi: typeof qBlock.q.max === "number" ? qBlock.q.max : 5
                Flow {
                    Layout.fillWidth: true; spacing: 6
                    Repeater {
                        model: qBlock.qt === "scale" ? Math.max(0, Math.min(101, parent.parent.hi - parent.parent.lo + 1)) : 0   // at most 101 (FR-7)
                        Rectangle {
                            property int v: parent.parent.lo + index
                            property bool stars: qBlock.q.style === "stars"
                            property bool on: stars ? (typeof qBlock.cur === "number" && v <= qBlock.cur) : qBlock.cur === v
                            width: stars ? 34 : 40; height: stars ? 34 : 36; radius: stars ? 17 : 8
                            color: stars ? "transparent" : (on ? fr.wbPrimary : fr.wbSurfaceRaised)
                            border.color: stars ? "transparent" : (on ? fr.wbPrimary : (qBlock.invalid ? fr.wbError : fr.wbBorder)); border.width: 1
                            Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: parent.stars ? "★" : String(parent.v)
                                font.pixelSize: parent.stars ? 26 : 13; font.weight: Font.DemiBold
                                color: parent.stars ? (parent.on ? fr.wbAccent : fr.wbBorder) : (parent.on ? "white" : fr.wbText) }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: fr.setAnswer(qBlock.q.id, parent.v) }
                        }
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: !!(qBlock.q.minLabel || qBlock.q.maxLabel)
                    Text { textFormat: Text.PlainText; text: qBlock.q.minLabel || ""; font.pixelSize: 11; color: fr.wbTextTert }
                    Item { Layout.fillWidth: true }
                    Text { textFormat: Text.PlainText; text: qBlock.q.maxLabel || ""; font.pixelSize: 11; color: fr.wbTextTert }
                }
            }
            Text { textFormat: Text.PlainText; visible: qBlock.invalid; text: qBlock.problem; font.pixelSize: 12; color: fr.wbError }
        }
    }

    WbButton {
        visible: !!(fr.form && (fr.form.canRespond || (fr.editing && fr.form.canEdit)))
        Layout.fillWidth: true
        implicitHeight: 46
        primary: true
        label: fr.host.busy("submitResponse") ? "Sealing..." : (fr.editing ? "Seal and send the edited answer" : "Seal and send answers")
        active: !fr.host.busy("submitResponse")
        onClicked: fr.doSubmit()
    }

    Rectangle {
        Layout.fillWidth: true
        visible: !!(fr.form && !fr.form.mine)
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
            LockIcon { tint: fr.wbSuccess; Layout.alignment: Qt.AlignTop }
            Text { textFormat: Text.PlainText;
                Layout.fillWidth: true
                text: "Answers are encrypted to the creator's key before they leave this device. Everyone else on the network - including peers that relay and store them - sees only an opaque blob. The receipt the creator sends back can't be linked to your address."
                wrapMode: Text.WordWrap
                font.pixelSize: 12
                color: fr.wbSuccess
            }
        }
    }
}
