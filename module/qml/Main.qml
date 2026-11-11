import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
// The host requires these imports for custom colours to apply (see 3b9640d);
// the view itself styles with its own palette below.
import Logos.Theme
import Logos.Controls
import "WbPalette.js" as P
import "WbAnswers.js" as WA

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

    // ── state ──
    property var st: ({})
    property string selectedId: ""
    property bool showHidden: false   // sidebar: expand the "Hidden" section
    property string toastMsg: ""
    property bool showCreate: false
    property bool showShare: false
    property bool showCsv: false
    property bool showIdentity: false
    property alias showErrors: respond.showErrors
    property alias answers: respond.answers
    property string shareText: ""
    property var qr: null
    property string csvText: ""
    property string draftTitle: ""
    property string draftDescription: ""
    property var draftQuestions: []
    property bool draftRestrict: false
    property string draftAllowList: ""
    // 0.3.2 builder extras + responses viewer
    property string draftId: ""            // saved draft being edited ("" = not saved yet)
    property string draftMax: ""           // max responses (text field)
    property string draftCloseAt: ""       // "yyyy-MM-dd HH:mm" or ""
    property bool draftShowCount: false
    property string draftThankYou: ""
    property bool draftShuffle: false
    property bool draftAllowEdits: false
    property bool draftMulti: false        // several answers per person (ADR 0022)
    property string draftPerPerson: ""     // ... up to this many ("" = no limit)
    property bool draftAnonymous: false
    property bool draftQuiz: false
    property string editingFormId: ""     // builder is editing a PUBLISHED form (form.update)
    property bool showCoOwners: false
    property alias editing: respond.editing
    property string draftPublishAt: ""     // schedule field
    property bool draftScheduling: false
    property bool draftDirty: false
    property bool builderLive: true        // toggled to re-create builder fields (bindings)
    property string respMode: "summary"    // summary | table | one
    property int respIndex: 0
    property string respFilter: ""

    readonly property var qTypes: [
        { t: "text", label: "Short text" }, { t: "textarea", label: "Paragraph" },
        { t: "radioButtons", label: "Single choice" }, { t: "checkbox", label: "Multiple choice" },
        { t: "boolean", label: "Yes / No" }, { t: "dropdown", label: "Dropdown" }, { t: "scale", label: "Scale" },
        { t: "number", label: "Number" }, { t: "date", label: "Date" }, { t: "time", label: "Time" },
        { t: "email", label: "Email" }, { t: "url", label: "Link" }
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
    function applySnapshot(o) { if (o && o.state) { root.st = o; Qt.callLater(root.checkSeen); Qt.callLater(root.loadDetail); } }
    // Looking at your own form = its answers are seen (clears the "N new" pill).
    property bool seenBusy: false
    function selectCappedForSeen() {   // (harness) open the first own form that has new answers
        for (var k in root.forms) if (root.forms[k].mine && root.forms[k].newResponses > 0 && root.forms[k].title === "Capped") { selectForm(k); return; }
    }
    function addCoOwnerHarness() { act("addCoOwner", [root.selectedId, "02" + "11".repeat(32)], ""); }   // (harness)
    function checkSeen() {
        var f = root.previewDef ? null : root.forms[root.selectedId];
        if (!f || !f.mine || !(f.newResponses > 0) || root.seenBusy) return;
        root.seenBusy = true;
        callVia("markSeen", [f.id], function () { root.seenBusy = false; });
    }
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
            if (o && o.state) { root.st = o; root.refreshMisses = 0; Qt.callLater(root.loadDetail); } else root.refreshMisses++;
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
    readonly property var watchedIds: (st.watched || [])
    readonly property var creatorView: st.creatorView || null
    readonly property var diag: st.diagnostics || ({})
    readonly property string myAddress: (st.identity && st.identity.address) ? st.identity.address : ""
    // Core can't persist (no writable folder): forms + identity would be lost on restart.
    readonly property bool storageBad: !!(st.storage && st.storage.ok === false)
    readonly property string storageNote: (st.storage && st.storage.note) ? st.storage.note : ""
    readonly property bool nodeReady: !!st.nodeReady
    // Preview: the builder's form shown as respondents see it (never sent).
    property var previewDef: null
    readonly property var sel: previewDef ? previewDef : withDetail(forms[selectedId] || null)
    // The selected form's private parts (answers, my answers, my replies, quiz key, answer draft) come
    // from formDetail, not the snapshot: the snapshot is also the stateChanged event any module can
    // receive (open-review 2026-11-03, FR-2).
    property var detail: ({})
    function withDetail(f) {
        if (!f || root.detail.formId !== f.id) return f;
        var o = Object.assign({}, f), ks = ["myAnswers", "myReplies", "quiz", "answerDraft"];
        for (var i = 0; i < ks.length; i++) if (root.detail[ks[i]] !== undefined) o[ks[i]] = root.detail[ks[i]];
        return o;
    }
    property bool detailBusy: false
    function loadDetail() {
        var id = root.selectedId;
        if (!id || root.previewDef || root.detailBusy) return;
        root.detailBusy = true;
        callVia("formDetail", [id], function (raw) {
            root.detailBusy = false;
            var r = parse(raw);
            if (!r || !r.ok || r.formId !== root.selectedId) return;
            var first = root.detail.formId !== r.formId;
            root.detail = r;
            if (first) restoreAnswerDraft();
        });
    }
    readonly property bool selPending: !sel && selectedId !== "" && pendingForms.indexOf(selectedId) >= 0
    readonly property var selResponses: responsesFor(selectedId)
    readonly property int selConfirmed: { var n = 0; for (var i = 0; i < selResponses.length; i++) if (selResponses[i].confirmed) n++; return n; }

    readonly property var drafts: st.drafts || []
    readonly property var selUnconfirmed: { var n = 0; for (var i = 0; i < selResponses.length; i++) if (!selResponses[i].confirmed) n++; return n; }
    // Table/one-by-one list: the search box matches the address or any answer text.
    readonly property var respList: {
        var t = root.respFilter.trim().toLowerCase();
        if (!t) return selResponses;
        var out = [];
        for (var i = 0; i < selResponses.length; i++) {
            var r = selResponses[i], hay = String(r.respondent || "");
            var a = r.answers || [];
            for (var k = 0; k < a.length; k++) hay += " " + answerText(questionFor(root.sel, a[k].questionId), a[k].value);
            if (hay.toLowerCase().indexOf(t) >= 0) out.push(r);
        }
        return out;
    }
    function answerOf(r, qid) {
        var a = (r && r.answers) ? r.answers : [];
        for (var i = 0; i < a.length; i++) if (a[i].questionId === qid) return a[i].value;
        return null;
    }
    // Per-question aggregate for the Summary view.
    function summaryFor(q) {
        var rs = root.selResponses, t = normType(q.type), i, j;
        var bars = function (labels, countFn) {
            var counts = labels.map(function () { return 0; }), answered = 0;
            for (i = 0; i < rs.length; i++) { var hit = countFn(answerOf(rs[i], q.id), counts); if (hit) answered++; }
            var max = 1; for (j = 0; j < counts.length; j++) max = Math.max(max, counts[j]);
            var rows = []; for (j = 0; j < labels.length; j++) rows.push({ label: String(labels[j]), n: counts[j], pct: answered ? Math.round(100 * counts[j] / answered) : 0, w: counts[j] / max });
            return { bars: true, rows: rows, answered: answered, samples: [], stat: "" };
        };
        if (t === "radioButtons" || t === "checkbox" || t === "dropdown" || t === "boolean") {
            var labels = t === "boolean" ? ["Yes", "No"] : (q.options || []).slice();
            var other = !!q.allowOther && t !== "boolean"; if (other) labels.push("Other");
            var r = bars(labels, function (v, c) {
                var hit = false, l = t === "boolean" ? [] : (isList(v) ? toList(v) : [v]);
                if (t === "boolean") { if (v === true) { c[0]++; hit = true; } else if (v === false) { c[1]++; hit = true; } return hit; }
                for (var k = 0; k < l.length; k++) {
                    if (typeof l[k] === "number" && l[k] >= 0 && l[k] < (q.options || []).length) { c[l[k]]++; hit = true; }
                    else if (other && isOtherVal(l[k])) { c[c.length - 1]++; hit = true; }
                }
                return hit;
            });
            if (other) { var os = []; for (i = rs.length - 1; i >= 0 && os.length < 5; i--) { var ov = answerOf(rs[i], q.id), ol = isList(ov) ? toList(ov) : [ov];
                for (j = 0; j < ol.length; j++) if (isOtherVal(ol[j]) && String(ol[j].other).trim()) os.push("Other: " + ol[j].other); } r.samples = os; }
            return r;
        }
        if (t === "scale") {
            var lo = typeof q.min === "number" ? q.min : 1, hi = typeof q.max === "number" ? q.max : 5, ls = [], sum = 0, cnt = 0;
            if (hi - lo > 100) hi = lo + 100;   // the core refuses wider scales (FR-7); never build a huge list
            for (var x = lo; x <= hi; x++) ls.push(String(x));
            var rsS = bars(ls, function (v, c) { if (typeof v === "number" && v >= lo && v <= hi) { c[v - lo]++; sum += v; cnt++; return true; } return false; });
            rsS.stat = cnt ? "average " + (Math.round(10 * sum / cnt) / 10) + (q.style === "stars" ? " ★" : "") + "  (" + (q.minLabel || lo) + " → " + (q.maxLabel || hi) + ")" : "";
            return rsS;
        }
        var texts = [], nums = [];
        for (var y = rs.length - 1; y >= 0; y--) { var av = answerOf(rs[y], q.id), s2 = answerText(q, av); if (s2) texts.push(s2); if (t === "number" && typeof av === "number") nums.push(av); }
        var stat = "";
        if (nums.length) { var mn = Math.min.apply(null, nums), mx = Math.max.apply(null, nums), sm = 0; for (var z = 0; z < nums.length; z++) sm += nums[z];
            stat = "min " + mn + "  ·  average " + (Math.round(100 * sm / nums.length) / 100) + "  ·  max " + mx; }
        return { bars: false, rows: [], answered: texts.length, samples: texts.slice(0, 5), stat: stat };
    }
    // "By question": every answer to one question
    property int byQIndex: 0
    readonly property var byQList: {
        var f = root.sel, out = []; if (!f || !f.questions || !f.questions.length) return out;
        var qi = Math.max(0, Math.min(root.byQIndex, f.questions.length - 1)), q = f.questions[qi];
        for (var i = 0; i < root.respList.length; i++) { var t = answerText(q, answerOf(root.respList[i], q.id)); out.push({ who: shortAddr(root.respList[i].respondent), when: root.respList[i].submittedAt, text: t }); }
        return out;
    }
    function responsesFor(fid) {
        if (root.detail.formId === fid && root.detail.responses) return root.detail.responses;   // with answers (formDetail)
        if (!creatorView || !creatorView.responses || !creatorView.responses[fid]) return [];   // counts and receipt state only
        return creatorView.responses[fid];
    }
    // Arrays from the host/model can be sequence wrappers (Array.isArray false).
    function answerTimeText(r) {
        if (!r) return "";
        if (r.timeVerified === true) return root.fmtTime(r.receivedAt) + (r.timeSkew ? "  (sender's clock says " + root.fmtTime(r.submittedAt) + ")" : "");
        if (r.timeVerified === false) return root.fmtTime(r.submittedAt) + "  (time not verified)";
        return root.fmtTime(r.submittedAt);
    }
    function questionFor(f, qid) {
        if (!f || !f.questions) return null;
        for (var i = 0; i < f.questions.length; i++) if (f.questions[i].id === qid) return f.questions[i];
        return null;
    }
    // Answer value -> display text (choice values are option indices).

    // Sidebar rows: section headers + form rows, grouped by relationship.
    readonly property var sidebarRows: {
        var mine = [], answered = [], open = [], hidden = [], coOwned = [], rows = [];
        var ids = Object.keys(root.forms);
        ids.sort(function (a, b) { return (root.forms[b].createdAt || 0) - (root.forms[a].createdAt || 0); });
        for (var i = 0; i < ids.length; i++) {
            var f = root.forms[ids[i]];
            // No public directory: a form is listed only if it's yours, you answered it, or you
            // opened its link. Everything else the node relays stays invisible (anyone can
            // publish, so a public list would be a spam channel).
            if (f.hidden) { hidden.push(f.id); continue; }   // local hide (Hide button)
            if (f.mine) mine.push(f.id);
            else if (f.coOwner) coOwned.push(f.id);
            else if (f.mySubmitted) answered.push(f.id);
            else if (root.watchedIds.indexOf(f.id) >= 0) open.push(f.id);
        }
        var newMine = 0;
        for (var nm = 0; nm < mine.length; nm++) newMine += (root.forms[mine[nm]].newResponses || 0);
        var add = function (label, list, kind) {
            if (list.length === 0) return;
            rows.push({ kind: "h", label: label + "  " + list.length + (label === "MY FORMS" && newMine > 0 ? "   \u00B7  " + newMine + " new" : "") });
            for (var k = 0; k < list.length; k++) rows.push({ kind: kind, id: list[k] });
        };
        if (root.drafts.length > 0) {
            rows.push({ kind: "hd", label: "DRAFTS  " + root.drafts.length + "   \u00B7  clear all" });
            for (var dd = 0; dd < root.drafts.length; dd++) rows.push({ kind: "d", id: root.drafts[dd].id, draft: root.drafts[dd] });
        }
        add("WAITING FOR SYNC", root.pendingForms, "p");
        add("MY FORMS", mine, "f");
        add("CO-OWNED", coOwned, "f");
        add("ANSWERED", answered, "f");
        add("OPENED FROM LINKS", open, "f");
        if (hidden.length > 0) {
            rows.push({ kind: "hh", label: "HIDDEN  " + hidden.length + "   \u00B7  " + (root.showHidden ? "hide" : "show") });
            if (root.showHidden) for (var h = 0; h < hidden.length; h++) rows.push({ kind: "f", id: hidden[h] });
        }
        return rows;
    }


    // ── answering lives in FormRespond.qml (shared with the respond module); these keep the studio's
    // and the test harness's names working ──
    function restoreAnswerDraft() { respond.restoreAnswerDraft(); }
    function setAnswer(qid, v) { respond.setAnswer(qid, v); }
    function saveAnswerDraftNow() { respond.saveAnswerDraftNow(); }
    function doSubmit() { respond.doSubmit(); }
    function startEditing() { respond.startEditing(); }
    function minutesLeft(until) { return respond.minutesLeft(until); }
    function problemOf(q) { return respond.problemOf(q); }
    // ── shared helpers (WbAnswers.js) ──
    function isList(v) { return WA.isList(v); }
    function toList(v) { return WA.toList(v); }
    function plural(n, one, many) { return WA.plural(n, one, many); }
    function shortAddr(a) { return WA.shortAddr(a); }
    function fmtTime(ms) { return WA.fmtTime(ms); }
    function normType(t) { return WA.normType(t); }
    function answerText(q, v) { return WA.answerText(q, v); }
    function isOtherVal(v) { return WA.isOtherVal(v); }
    function emptyVal(v) { return WA.emptyVal(v); }

    // ── actions ──
    function selectForm(id) {
        respond.flushDraft();   // save the half-filled answers of the form we're leaving
        if (root.selectedId !== id) { root.detail = ({}); respond.reset(); }
        root.selectedId = id; root.showErrors = false; root.respIndex = 0; root.respFilter = ""; root.editing = false;
        Qt.callLater(root.checkSeen);
        restoreAnswerDraft();
        Qt.callLater(root.loadDetail);
    }
    // Half-filled answers saved while typing come back (crash, restart, switching forms).
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
    // ── answer rules (mirror contract/src/answers.mjs; the core enforces them too) ──
    // Deterministic shuffle per respondent + form (stable across restarts, different per person).
    readonly property bool selQuiz: !!(root.sel && root.sel.quiz)
    readonly property int selUnscored: {
        var n = 0; if (!root.selQuiz) return 0;
        for (var i = 0; i < root.selResponses.length; i++) { var r = root.selResponses[i]; if (!(r.replies > 0) && r.replyPub) n++; }
        return n;
    }
    readonly property string selAvgScore: {
        if (!root.selQuiz || !root.selResponses.length) return "";
        var t = 0, of = 0;
        for (var i = 0; i < root.selResponses.length; i++) { t += Number(root.selResponses[i].score || 0); of = Number(root.selResponses[i].outOf || 0); }
        return (Math.round(t / root.selResponses.length * 10) / 10) + " / " + of;
    }
    function scoreText(r) { return r && r.outOf !== undefined ? String(r.score) + " / " + String(r.outOf) : ""; }
    function sendScoresSelected() {
        act("sendScores", [root.selectedId], "", function (r) {
            toast(r.sent ? "Scores sent privately to " + root.plural(r.sent, "person", "people") + (r.skipped ? " (" + r.skipped + " answered with an older WhisperBox)" : "") : "Everyone already has a reply");
        });
    }
    function sendReply(cid, text, done) {
        act("replyToResponse", [root.selectedId, cid, text], "Reply sent - only this person can read it", done);
    }
    function confirmResponse(addr) { act("confirmResponse", [root.selectedId, addr], "Receipt sent"); }
    // one answer's receipt: by its receipt id (forms taking several answers per person, ADR 0022)
    function confirmOne(r) {
        if (r && r.confirmationId && root.sel && root.sel.maxPerRespondent !== undefined) act("confirmAnswer", [root.selectedId, r.confirmationId], "Receipt sent");
        else if (r) confirmResponse(r.respondent);
    }
    // answers and receipts per person, most received first (rewards: count what you received)
    function respondentTally() {
        var by = ({}), out = [];
        for (var i = 0; i < root.selResponses.length; i++) {
            var r = root.selResponses[i]; if (r.verified === false) continue;
            var k = String(r.respondent || ""); if (!by[k]) { by[k] = { respondent: k, answers: 0, received: 0 }; out.push(by[k]); }
            by[k].answers++; if (r.confirmed) by[k].received++;
        }
        out.sort(function (a, b) { return b.received - a.received || b.answers - a.answers; });
        return out;
    }
    function toggleHidden() {
        var f = root.sel; if (!f) return;
        var hide = !f.hidden;
        act(hide ? "hideForm" : "unhideForm", [f.id], hide ? "Hidden - find it under Hidden in the sidebar" : "Back in your lists", function () {
            if (hide && !root.showHidden) root.selectedId = "";
        });
    }
    property string removeArmed: ""
    function removeSelected() {
        var f = root.sel; if (!f) return;
        if (root.removeArmed !== f.id) { root.removeArmed = f.id; return; }
        root.removeArmed = "";
        act("deleteLocalForm", [f.id], "Removed from this device - open the creator's link to add it again", function () { root.selectedId = ""; });
    }
    function reopenSelected() { act("reopenForm", [root.selectedId], "Form re-opened - answers sealed while it was closed still don't count"); }
    function confirmAllSelected() {
        act("confirmAll", [root.selectedId], "", function (r) { toast(r.confirmed ? "Receipts sent for " + root.plural(r.confirmed, "response", "responses") : "Everything already has a receipt"); });
    }
    function toggleAutoReceipts() {
        var on = !(root.sel && root.sel.autoReceipts);
        act("setAutoReceipts", [root.selectedId, on ? "1" : "0"], on ? "Receipts now go out automatically" : "Automatic receipts off");
    }
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
    // asks once more, naming the address it replaces; the old key is kept as identity.json.prev
    // (open-review 2026-11-03, FR-4)
    property bool confirmImport: false
    Timer { id: importTimer; interval: 6000; onTriggered: root.confirmImport = false }
    function importKey() {
        var k = String(keyField.text || "").trim().replace(/^0x/, "");
        if (!root.confirmImport) { root.confirmImport = true; importTimer.restart(); toast("This replaces " + root.shortAddr(root.myAddress) + " on this device - click Import again to go ahead"); return; }
        root.confirmImport = false;
        act("importIdentity", [k], "Identity imported - the previous key is kept as identity.json.prev in the data folder", function () { keyField.text = ""; });
    }
    // passphrase over the key and the saved answers (open-review 2026-11-03, FR-13)
    readonly property bool idProtected: !!(st.identity && st.identity.protected)
    readonly property var lockedId: st.locked || null
    function unlockWith(p, done) {
        act("unlock", [String(p || "")], "Unlocked", function () { if (done) done(); });
    }
    function unlockFromField() { unlockWith(unlockField.text, function () { unlockField.text = ""; }); }
    function setPass(cur, next, again, done) {
        if (String(next || "") !== String(again || "")) { toast("The new passphrases don't match"); return; }
        act("setPassphrase", [String(cur || ""), String(next || "")], next ? "Passphrase set - you'll enter it when WhisperBox starts" : "Passphrase removed", function () { if (done) done(); });
    }

    // ── create-form builder (drafts autosave; publish now / schedule) ──
    function rebuildBuilder() { root.builderLive = false; Qt.callLater(function () { root.builderLive = true; }); }
    function resetBuilder() {
        root.draftId = ""; root.draftTitle = ""; root.draftDescription = ""; root.draftRestrict = false; root.draftAllowList = "";
        root.draftQuestions = [{ type: "text", text: "", required: true, optionsText: "" }];
        root.draftMax = ""; root.draftCloseAt = ""; root.draftShowCount = false; root.draftPublishAt = ""; root.draftScheduling = false;
        root.draftThankYou = ""; root.draftShuffle = false; root.draftAllowEdits = false; root.draftAnonymous = false; root.draftQuiz = false; root.draftMulti = false; root.draftPerPerson = "";
    }
    function openCreate() { resetBuilder(); root.editingFormId = ""; rebuildBuilder(); root.draftDirty = false; root.showCreate = true; }
    // Edit a published form: same builder, existing questions keep their ids (answers are
    // stored by question id), saved as a form.update - no draft, no scheduling.
    function openEditForm() {
        var f = root.sel; if (!f || !f.mine) return;
        var qs = [];
        for (var i = 0; i < (f.questions || []).length; i++) {
            var q = f.questions[i], dq = Object.assign({}, q); delete dq.options;
            dq.type = normType(q.type); dq.optionsText = (q.options || []).join("\n");
            if (q.type === "number") { dq.numMin = q.min !== undefined ? String(q.min) : ""; dq.numMax = q.max !== undefined ? String(q.max) : ""; }
            quizIntoDraft(dq, f.quiz && f.quiz[q.id]);
            qs.push(dq);
        }
        loadBuilder({ title: f.title || "", description: f.description || "", questions: qs, restrict: !!(f.whitelist && f.whitelist.type === "addresses"),
                      allowList: (f.whitelist && f.whitelist.value || "").split(",").join("\n"), max: f.maxResponses ? String(f.maxResponses) : "",
                      closeAt: f.expiresAt ? Qt.formatDateTime(new Date(Number(f.expiresAt)), "yyyy-MM-dd HH:mm") : "",
                      showCount: !!f.showResponseCount, thankYou: f.thankYou || "", shuffle: !!f.shuffleQuestions, allowEdits: !!f.allowEdits, anonymous: !!f.anonymous, quiz: !!f.quiz,
                      multi: f.maxPerRespondent !== undefined && f.maxPerRespondent !== 1, perPerson: f.maxPerRespondent > 1 ? String(f.maxPerRespondent) : "" });
        root.editingFormId = f.id;
        rebuildBuilder(); root.draftDirty = false; root.showCreate = true;
    }
    function doUpdate() {
        var b = buildDef(true);
        if (!b.ok) { toast(b.error); return; }
        var def = Object.assign({}, b.def); delete def._builder;
        var fid = root.editingFormId;
        act("updateForm", [fid, JSON.stringify(def)], "Form updated - everyone sees the new version", function () {
            root.draftDirty = false; root.showCreate = false; root.editingFormId = "";
        });
    }
    // ── quiz: the right answer per question, kept on the draft question ──
    //   choice/dropdown: correct = index; checkbox: correctSet = [index]; boolean: correct = true|false;
    //   text types: accepted = "a, b"; scale/number: correctNum = "4"; points = "2"
    function quizScorable(t) { return ["radioButtons", "dropdown", "checkbox", "boolean", "text", "textarea", "email", "url", "scale", "number"].indexOf(t) >= 0; }
    function quizIntoDraft(dq, k) {
        if (!k || !("answer" in k)) return;
        var a = k.answer;
        if (dq.type === "checkbox") dq.correctSet = Array.isArray(a) ? a.slice() : [];
        else if (dq.type === "scale" || dq.type === "number") dq.correctNum = String(a);
        else if (Array.isArray(a)) dq.accepted = a.join(", ");
        else dq.correct = a;
        if (typeof k.points === "number" && k.points !== 1) dq.points = String(k.points);
    }
    // -> {answer, points} | null (no right answer marked)
    function quizKeyOf(d) {
        var a;
        if (d.type === "radioButtons" || d.type === "dropdown") { if (typeof d.correct !== "number" || d.correct < 0) return null; a = d.correct; }
        else if (d.type === "boolean") { if (typeof d.correct !== "boolean") return null; a = d.correct; }
        else if (d.type === "checkbox") { if (!Array.isArray(d.correctSet) || !d.correctSet.length) return null; a = d.correctSet.slice().sort(function (x, y) { return x - y; }); }
        else if (d.type === "scale" || d.type === "number") { var t = String(d.correctNum || "").trim(); if (t === "" || isNaN(Number(t))) return null; a = Number(t); }
        else if (quizScorable(d.type)) {
            a = String(d.accepted || "").split(",").map(function (x) { return x.trim(); }).filter(function (x) { return x.length > 0; });
            if (!a.length) return null;
        } else return null;
        var k = { answer: a };
        var pt = String(d.points || "").trim();
        if (pt !== "" && !isNaN(Number(pt)) && Number(pt) >= 0 && Number(pt) !== 1) k.points = Number(pt);
        return k;
    }
    function toggleCorrectSet(qi, idx) {
        var cur = (root.draftQuestions[qi].correctSet || []).slice();
        var at = cur.indexOf(idx);
        if (at >= 0) cur.splice(at, 1); else cur.push(idx);
        root.setDraft(qi, "correctSet", cur);
    }
    function loadBuilder(b) {
        resetBuilder();
        root.draftTitle = b.title || ""; root.draftDescription = b.description || "";
        root.draftQuestions = (b.questions && b.questions.length) ? b.questions : root.draftQuestions;
        root.draftRestrict = !!b.restrict; root.draftAllowList = b.allowList || "";
        root.draftMax = b.max || ""; root.draftCloseAt = b.closeAt || ""; root.draftShowCount = !!b.showCount;
        root.draftThankYou = b.thankYou || ""; root.draftShuffle = !!b.shuffle; root.draftAllowEdits = !!b.allowEdits; root.draftAnonymous = !!b.anonymous; root.draftQuiz = !!b.quiz;
        root.draftMulti = !!b.multi; root.draftPerPerson = b.perPerson || "";
    }
    function openDraft(d) {
        var b = (d.def && d.def._builder) ? d.def._builder : null;
        if (!b) { toast("This draft can't be edited here"); return; }
        loadBuilder(b);
        root.draftId = d.id;
        if (d.publishAt) { root.draftScheduling = true; root.draftPublishAt = Qt.formatDateTime(new Date(Number(d.publishAt)), "yyyy-MM-dd HH:mm"); }
        rebuildBuilder(); root.draftDirty = false; root.showCreate = true;
    }
    // Published forms can't be edited - duplicate one into a new draft instead.
    function duplicateSelected() {
        var f = root.sel; if (!f) return;
        var qs = [];
        for (var i = 0; i < (f.questions || []).length; i++) {
            var q = f.questions[i];
            var dq = Object.assign({}, q); delete dq.id; delete dq.options;
            dq.type = normType(q.type); dq.text = q.text || ""; dq.required = !!q.required; dq.optionsText = (q.options || []).join("\n");
            quizIntoDraft(dq, f.quiz && f.quiz[q.id]);
            qs.push(dq);
        }
        loadBuilder({ title: (f.title || "") + " (copy)", description: f.description || "", questions: qs,
                      restrict: !!(f.whitelist && f.whitelist.type === "addresses"), allowList: (f.whitelist && f.whitelist.value || "").split(",").join("\n"),
                      max: f.maxResponses ? String(f.maxResponses) : "", showCount: !!f.showResponseCount, thankYou: f.thankYou || "", shuffle: !!f.shuffleQuestions,
                      allowEdits: !!f.allowEdits, anonymous: !!f.anonymous, quiz: !!f.quiz,
                      multi: f.maxPerRespondent !== undefined && f.maxPerRespondent !== 1, perPerson: f.maxPerRespondent > 1 ? String(f.maxPerRespondent) : "" });
        rebuildBuilder(); root.draftDirty = true; root.showCreate = true;
    }
    readonly property var templates: [
        { name: "Event RSVP", b: { title: "Are you coming?", description: "Let us know by Friday.", questions: [
            { type: "boolean", text: "Will you attend?", required: true, optionsText: "" },
            { type: "number", text: "How many guests are you bringing?", required: false, optionsText: "", numMin: "0", numMax: "10" },
            { type: "radioButtons", text: "Food preference", required: false, optionsText: "Anything\nVegetarian\nVegan", allowOther: true },
            { type: "textarea", text: "Anything we should know?", required: false, optionsText: "" }], thankYou: "Thanks - see you there!" } },
        { name: "Feedback", b: { title: "How did we do?", description: "", questions: [
            { type: "scale", text: "Overall, how satisfied are you?", required: true, optionsText: "", min: 1, max: 5, style: "stars" },
            { type: "checkbox", text: "What did you like?", required: false, optionsText: "Content\nSpeakers\nVenue\nPeople", allowOther: true },
            { type: "textarea", text: "What should we improve?", required: false, optionsText: "" }], thankYou: "Thank you for the feedback!" } },
        { name: "Quick poll", b: { title: "Quick poll", description: "", questions: [
            { type: "radioButtons", text: "Which option do you prefer?", required: true, optionsText: "Option A\nOption B\nOption C", shuffleOptions: true }] } },
        { name: "Sign-up sheet", b: { title: "Sign up", description: "", questions: [
            { type: "text", text: "Name", required: true, optionsText: "" },
            { type: "email", text: "Email (optional - only the organiser sees it)", required: false, optionsText: "" },
            { type: "dropdown", text: "Slot", required: true, optionsText: "Morning\nAfternoon\nEvening" }] } },
        { name: "NPS", b: { title: "Would you recommend us?", description: "", questions: [
            { type: "scale", text: "How likely are you to recommend us to a friend?", required: true, optionsText: "", min: 0, max: 10, minLabel: "Not likely", maxLabel: "Very likely" },
            { type: "textarea", text: "What's the main reason for your score?", required: false, optionsText: "" }] } }
    ]
    function useTemplateNps() { useTemplate(4); }   // (harness: invokable without args)
    function useTemplate(i) { loadBuilder(JSON.parse(JSON.stringify(templates[i].b))); rebuildBuilder(); root.draftDirty = true; }
    property var answersBeforePreview: ({})
    function openPreview() {
        var b = buildDef(false);
        var d = b.def;
        root.answersBeforePreview = root.answers; root.answers = ({}); root.showErrors = false;
        root.previewDef = { id: "preview", title: d.title || "(untitled)", description: d.description, questions: d.questions, whitelist: d.whitelist,
            creator: root.myAddress, status: "open", canRespond: true, allowed: true, mine: false, confirmations: [],
            maxResponses: d.maxResponses, expiresAt: d.expiresAt, showResponseCount: !!d.showResponseCount, thankYou: d.thankYou || "", shuffleQuestions: !!d.shuffleQuestions };
        root.showCreate = false;
    }
    function closePreview() { root.previewDef = null; root.answers = root.answersBeforePreview; root.showCreate = true; }
    function addDraftQuestion() { root.draftQuestions = root.draftQuestions.concat([{ type: "text", text: "", required: false, optionsText: "" }]); }
    function removeDraftQuestion(i) { var a = root.draftQuestions.slice(); a.splice(i, 1); root.draftQuestions = a; rebuildBuilder(); }
    function moveDraftQuestion(i, d) {
        var j = i + d; if (j < 0 || j >= root.draftQuestions.length) return;
        var a = root.draftQuestions.slice(); var t = a[i]; a[i] = a[j]; a[j] = t; root.draftQuestions = a; rebuildBuilder();
    }
    function duplicateDraftQuestion(i) {
        var c = Object.assign({}, root.draftQuestions[i]); delete c.id;   // a copy is a NEW question
        var a = root.draftQuestions.slice(); a.splice(i + 1, 0, c); root.draftQuestions = a; rebuildBuilder();
    }
    function setDraft(i, prop, v) { if (i < 0 || i >= root.draftQuestions.length) return; var a = root.draftQuestions.slice(); var q = Object.assign({}, a[i]); q[prop] = v; a[i] = q; root.draftQuestions = a; }
    function draftOptions(q) {
        var out = [], lines = String(q.optionsText || "").split("\n");
        for (var i = 0; i < lines.length; i++) { var s = lines[i].trim(); if (s) out.push(s); }
        return out;
    }
    function parseLocal(s) {   // "yyyy-MM-dd HH:mm" (local time) -> ms, or NaN
        var m = /^\s*(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{1,2}):(\d{2}))?\s*$/.exec(String(s || ""));
        if (!m) return NaN;
        return new Date(+m[1], +m[2] - 1, +m[3], m[4] ? +m[4] : 23, m[5] ? +m[5] : 59).getTime();
    }
    // Everything the builder shows - stored inside the draft so it reopens exactly.
    readonly property var builderState: ({ title: root.draftTitle, description: root.draftDescription, questions: root.draftQuestions,
        restrict: root.draftRestrict, allowList: root.draftAllowList, max: root.draftMax, closeAt: root.draftCloseAt, showCount: root.draftShowCount,
        thankYou: root.draftThankYou, shuffle: root.draftShuffle, allowEdits: root.draftAllowEdits, anonymous: root.draftAnonymous, quiz: root.draftQuiz,
        multi: root.draftMulti, perPerson: root.draftPerPerson })
    onBuilderStateChanged: if (root.showCreate) root.draftDirty = true
    // -> { ok, def, error }. strict=false never fails (autosave of a half-done form).
    function buildDef(strict) {
        var err = function (m) { return { ok: false, error: m }; };
        var title = root.draftTitle.trim();
        if (strict && !title) return err("Give the form a title");
        var qs = [], used = {}, next = 1, quiz = {}, nQuiz = 0;
        for (var u = 0; u < root.draftQuestions.length; u++) { var m0 = /^q(\d+)$/.exec(String(root.draftQuestions[u].id || "")); if (root.draftQuestions[u].id) used[root.draftQuestions[u].id] = true; if (m0) next = Math.max(next, +m0[1] + 1); }
        var fresh = function () { while (used["q" + next]) next++; used["q" + next] = true; return "q" + next++; };
        var anyIds = Object.keys(used).length > 0;
        for (var i = 0; i < root.draftQuestions.length; i++) {
            var d = root.draftQuestions[i], text = String(d.text || "").trim();
            if (!text) continue;
            // existing questions keep their id (answers are stored by id); new ones get a fresh one
            var q = { id: d.id ? d.id : (anyIds ? fresh() : "q" + (qs.length + 1)), type: d.type, text: text, required: !!d.required };
            if (String(d.help || "").trim()) q.help = String(d.help).trim();
            if (d.type === "radioButtons" || d.type === "checkbox" || d.type === "dropdown") {
                q.options = draftOptions(d);
                if (strict && q.options.length < 2) return err("\"" + text + "\" needs at least two options");
                if (d.allowOther) q.allowOther = true;
                if (d.shuffleOptions) q.shuffleOptions = true;
            }
            if (d.type === "scale") {
                q.min = d.min === 0 ? 0 : 1; q.max = [3, 4, 5, 7, 10].indexOf(d.max) >= 0 ? d.max : 5;
                if (String(d.minLabel || "").trim()) q.minLabel = String(d.minLabel).trim();
                if (String(d.maxLabel || "").trim()) q.maxLabel = String(d.maxLabel).trim();
                if (d.style === "stars") q.style = "stars";
            }
            if (d.type === "number") {
                var mn = String(d.numMin || "").trim(), mx = String(d.numMax || "").trim();
                if (mn !== "" && !isNaN(Number(mn))) q.min = Number(mn);
                if (mx !== "" && !isNaN(Number(mx))) q.max = Number(mx);
                if (strict && q.min !== undefined && q.max !== undefined && q.min > q.max) return err("\"" + text + "\": minimum is above maximum");
            }
            if (root.draftQuiz) { var qk = quizKeyOf(d); if (qk) { quiz[q.id] = qk; nQuiz++; } }
            qs.push(q);
        }
        if (strict && qs.length === 0) return err("Add at least one question");
        var wl = { type: "none", value: "" };
        if (root.draftRestrict) {
            var addrs = root.draftAllowList.split(/[\s,]+/).filter(function (a) { return /^0x[0-9a-fA-F]{40}$/.test(a); });
            if (strict && addrs.length === 0) return err("Add at least one 0x address, or turn off the restriction");
            wl = { type: "addresses", value: addrs.join(",").toLowerCase() };
        }
        var def = { title: title, description: root.draftDescription.trim(), questions: qs, whitelist: wl, _builder: root.builderState };
        var max = root.draftMax.trim();
        if (max) { var n = parseInt(max, 10); if (strict && (!(n > 0) || String(n) !== max)) return err("Max responses must be a whole number"); if (n > 0) def.maxResponses = n; }
        var ca = root.draftCloseAt.trim();
        if (ca) { var t = parseLocal(ca); if (strict && isNaN(t)) return err("Close date: use yyyy-MM-dd HH:mm"); if (strict && t <= Date.now()) return err("Close date is in the past"); if (!isNaN(t)) def.expiresAt = t; }
        if (root.draftShowCount) def.showResponseCount = true;
        if (root.draftThankYou.trim()) def.thankYou = root.draftThankYou.trim();
        if (root.draftShuffle) def.shuffleQuestions = true;
        if (root.draftAllowEdits) { def.allowEdits = true; def.editWindowMinutes = 15; }
        if (root.draftMulti) {   // ADR 0022: 0 = no limit
            var pp = root.draftPerPerson.trim(), np = pp ? parseInt(pp, 10) : 0;
            if (strict && pp && (!(np > 1) || String(np) !== pp)) return err("Answers per person: a whole number above 1, or leave it empty for no limit");
            def.maxPerRespondent = np > 1 ? np : 0;
            if (strict && root.draftAllowEdits) return err("A form that takes several answers per person can't also allow edits");
        }
        if (root.draftQuiz) {
            if (strict && nQuiz === 0) return err("Quiz: mark the right answer for at least one question");
            if (nQuiz > 0) def.quiz = quiz;
        }
        if (root.draftAnonymous) { def.anonymous = true; if (strict && root.draftRestrict) return err("An anonymous form can't be members-only - it would need real addresses"); }
        return { ok: true, def: def };
    }
    function builderEmpty() {
        if (root.draftTitle.trim() || root.draftDescription.trim()) return false;
        for (var i = 0; i < root.draftQuestions.length; i++) if (String(root.draftQuestions[i].text || "").trim()) return false;
        return true;
    }
    function saveCurrentDraft(publishAt, cb) {
        var b = buildDef(publishAt !== undefined && publishAt !== null);
        if (!b.ok) { toast(b.error); return; }
        var d = { def: b.def };
        if (root.draftId) d.id = root.draftId;
        else {   // the same form opened again (a template, untouched): reuse its draft, don't add another (FR-9)
            var same = JSON.stringify(b.def);
            for (var i = 0; i < root.drafts.length; i++) if (JSON.stringify(root.drafts[i].def) === same) { d.id = root.drafts[i].id; break; }
        }
        if (publishAt) d.publishAt = publishAt;
        callVia("saveDraft", [JSON.stringify(d)], function (raw) {
            // callVia hands back the RAW string: parse it (reading .ok on the string made every
            // save look failed - no toast, no id kept, and autosave minted a new draft each time)
            var r = root.parse(raw);
            if (r && r.ok) { root.draftId = r.draftId; root.draftDirty = false; if (cb) cb(r); }
            else { root.draftDirty = false; toast("Couldn't save the draft: " + ((r && r.error) || "no answer from the WhisperBox core - is it updated too?")); }
        });
    }
    function saveCurrentDraftNow() { saveCurrentDraft(null, function () { toast("Draft saved"); }); }
    Timer { id: draftAutosave; interval: 2500; repeat: true; running: root.showCreate && root.draftDirty && !root.editingFormId
            onTriggered: if (!root.builderEmpty()) root.saveCurrentDraft(null) }
    function closeBuilder() {
        if (root.editingFormId) { if (root.draftDirty) toast("Changes not saved"); root.showCreate = false; root.editingFormId = ""; return; }
        if (root.draftDirty && !builderEmpty()) saveCurrentDraft(null, function () { toast("Saved as a draft"); });
        else if (root.draftId && builderEmpty()) callVia("deleteDraft", [root.draftId], function () {});
        root.showCreate = false;
    }
    property bool confirmClearDrafts: false
    function clearDrafts() {
        if (!root.confirmClearDrafts) { root.confirmClearDrafts = true; toast("Click again to delete all " + root.drafts.length + " drafts"); clearDraftsTimer.restart(); return; }
        root.confirmClearDrafts = false;
        var ids = root.drafts.map(function (d) { return d.id; });
        for (var i = 0; i < ids.length; i++) callVia("deleteDraft", [ids[i]], function () {});
        toast("Deleted " + root.plural(ids.length, "draft", "drafts"));
    }
    Timer { id: clearDraftsTimer; interval: 4000; onTriggered: root.confirmClearDrafts = false }
    // asks once more (open-review 2026-11-03, FR-9); a deleted draft is kept in the core's trash
    property bool confirmDiscard: false
    Timer { id: discardTimer; interval: 4000; onTriggered: root.confirmDiscard = false }
    function discardDraft() {
        if (!root.confirmDiscard) { root.confirmDiscard = true; discardTimer.restart(); toast("Click Delete draft again to delete it"); return; }
        root.confirmDiscard = false;
        if (root.draftId) act("deleteDraft", [root.draftId], "Draft deleted");
        root.draftDirty = false; root.showCreate = false;
    }
    function doCreate() {
        var b = buildDef(true);
        if (!b.ok) { toast(b.error); return; }
        var did = root.draftId;
        var def = Object.assign({}, b.def); delete def._builder;   // builder state is for drafts only
        act("createForm", [JSON.stringify(def)], "Form published", function (r) {
            if (did) callVia("deleteDraft", [did], function () {});
            root.draftDirty = false; root.showCreate = false; selectForm(String(r.formId || "").toLowerCase());
        });
    }
    function doSchedule() {
        var t = parseLocal(root.draftPublishAt);
        if (isNaN(t)) { toast("Publish time: use yyyy-MM-dd HH:mm"); return; }
        if (t <= Date.now()) { toast("That time has passed - use Publish now"); return; }
        saveCurrentDraft(t, function () {
            root.showCreate = false;
            toast("Scheduled for " + root.fmtTime(t) + " - publishes when WhisperBox is running then");
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
    component FormGlyph: Rectangle {
        implicitWidth: 32; implicitHeight: 32; radius: 8; color: root.wbPrimarySubtle
        Column {
            anchors.centerIn: parent; spacing: 3
            Rectangle { width: 14; height: 2; radius: 1; color: root.wbPrimary }
            Rectangle { width: 10; height: 2; radius: 1; color: root.wbPrimary }
            Rectangle { width: 12; height: 2; radius: 1; color: root.wbPrimary }
        }
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
                            placeholderText: "the creator's whisperbox:// link (a bare form id only shows the form)"
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
                        property bool isHead: modelData.kind === "h" || modelData.kind === "hh" || modelData.kind === "hd"
                        height: isHead ? 30 : 54
                        property var f: modelData.kind === "f" ? root.forms[modelData.id] : null
                        property bool current: !isHead && modelData.id === root.selectedId

                        SectionLabel {
                            visible: row.isHead
                            anchors.left: parent.left
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 6
                            text: row.isHead ? modelData.label : ""
                        }
                        MouseArea {
                            visible: modelData.kind === "hh" || modelData.kind === "hd"
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: modelData.kind === "hh" ? root.showHidden = !root.showHidden : root.clearDrafts()
                        }
                        Rectangle {
                            visible: !row.isHead
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
                                        text: row.f ? (row.f.title || "(untitled)") : (modelData.kind === "d" ? ((modelData.draft.def && modelData.draft.def.title) || "Untitled draft") : (modelData.id || ""))
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
                                            if (modelData.kind === "d") return modelData.draft.publishAt ? "scheduled  ·  " + root.fmtTime(modelData.draft.publishAt) : "draft  ·  edited " + root.fmtTime(modelData.draft.updatedAt);
                                            if (!row.f) return "syncing...";
                                            var parts = [root.plural(row.f.questions.length, "question", "questions")];
                                            if (row.f.mine) parts.push(root.plural(root.responsesFor(row.f.id).length, "response", "responses"));
                                            if (row.f.status === "closed") parts.push("closed");
                                            return parts.join("  ·  ");
                                        }
                                    }
                                }
                                Badge {
                                    visible: !!(row.f && row.f.mine && row.f.newResponses > 0)
                                    label: row.f ? row.f.newResponses + " new" : ""
                                    fg: "white"; bg: root.wbPrimary
                                }
                                Badge {
                                    visible: !!(row.f && !row.f.mine && row.f.mySubmitted)
                                    label: row.f && row.f.myConfirmed ? "Confirmed" : "Sent"
                                    fg: row.f && row.f.myConfirmed ? root.wbSuccess : root.wbTextSec
                                    bg: row.f && row.f.myConfirmed ? root.wbSuccessSubtle : root.wbSurfaceRaised
                                }
                            }
                            MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                onClicked: modelData.kind === "d" ? root.openDraft(modelData.draft) : root.selectForm(modelData.id) }
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

                Rectangle {
                    visible: root.storageBad
                    Layout.fillWidth: true
                    implicitHeight: storageT.implicitHeight + 16
                    radius: 8
                    color: Qt.rgba(0.97, 0.44, 0.44, 0.12)
                    border.color: root.wbError
                    Text {
                        id: storageT
                        textFormat: Text.PlainText
                        anchors.fill: parent; anchors.margins: 8
                        wrapMode: Text.WordWrap
                        text: "Not saving: " + root.storageNote
                        font.pixelSize: 11; color: root.wbError
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

                    Rectangle {   // preview banner
                        visible: !!root.previewDef
                        Layout.fillWidth: true
                        implicitHeight: pvRow.implicitHeight + 20
                        radius: 12; color: root.wbWarningSubtle; border.color: root.wbAccent; border.width: 1
                        RowLayout {
                            id: pvRow; anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; anchors.margins: 12
                            Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: "Preview - this is what respondents will see. Nothing you enter here is sent."; font.pixelSize: 13; color: root.wbAccent }
                            WbButton { label: "Back to editing"; primary: true; onClicked: root.closePreview() }
                        }
                    }
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
                        WbButton { visible: !!root.sel && !root.previewDef; label: root.sel && root.sel.hidden ? "Unhide" : "Hide"; enabled: !root.busy(root.sel && root.sel.hidden ? "unhideForm" : "hideForm"); onClicked: root.toggleHidden() }
                        Badge { visible: !!(root.sel && root.sel.coOwner); label: "Co-owner"; fg: root.wbPrimary; bg: root.wbPrimarySubtle }
                        WbButton { visible: !!(root.sel && root.sel.mine) && !root.previewDef; label: "Edit"; onClicked: root.openEditForm() }
                        WbButton { visible: !!root.sel && !root.previewDef; label: "Duplicate"; onClicked: root.duplicateSelected() }
                        WbButton { visible: !!root.sel && !root.previewDef; label: "Share"; onClicked: root.openShare() }
                        // drops the form and its creator pin from this device, so the right link can be
                        // opened (open-review 2026-11-02, FR-13); asks once more
                        WbButton { visible: !!root.sel && !root.previewDef && !root.sel.mine && !root.sel.coOwner
                                   label: root.removeArmed === (root.sel ? root.sel.id : "") ? "Really remove?" : "Remove"
                                   enabled: !root.busy("deleteLocalForm"); onClicked: root.removeSelected() }
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
                        Badge { visible: !!(root.sel && root.sel.anonymous); label: "Anonymous"; fg: root.wbPrimary; bg: root.wbPrimarySubtle }
                        Text { textFormat: Text.PlainText;
                            height: 20
                            verticalAlignment: Text.AlignVCenter
                            text: root.sel ? "by " + root.shortAddr(root.sel.creator) + (root.sel.createdAt ? "  ·  " + root.fmtTime(root.sel.createdAt) : "")
                                  + (root.sel.version > 1 && root.sel.updatedAt ? "  ·  updated " + root.fmtTime(root.sel.updatedAt) : "") : ""
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
                        visible: !!(root.sel && (root.sel.mine || root.sel.coOwner))
                        spacing: 16

                        Text { textFormat: Text.PlainText; visible: !!(root.sel && root.sel.coOwner); Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbTextSec
                            text: "You co-own this form: you can read its answers and send receipts. Closing and editing stay with its creator (" + root.shortAddr(root.sel ? root.sel.creator : "") + ")." }

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

                        // ── toolbar: lifecycle + receipts ──
                        Flow {
                            Layout.fillWidth: true
                            spacing: 8
                            WbButton {
                                visible: !!(root.sel && root.sel.mine && root.sel.status === "open")
                                label: "Close form"; danger: true
                                onClicked: root.closeSelected()
                            }
                            WbButton {
                                // not when it closed at its answer limit or end date (it would just close again)
                                visible: !!(root.sel && root.sel.mine && root.sel.status === "closed" && !(root.sel.maxResponses && root.selResponses.length >= root.sel.maxResponses)
                                            && !(root.sel.expiresAt && Date.now() > root.sel.expiresAt))
                                label: root.busy("reopenForm") ? "Re-opening..." : "Re-open form"
                                active: !root.busy("reopenForm")
                                onClicked: root.reopenSelected()
                            }
                            WbButton {
                                visible: root.selUnconfirmed > 0
                                primary: true
                                label: root.busy("confirmAll") ? "Sending..." : "Send all receipts (" + root.selUnconfirmed + ")"
                                active: !root.busy("confirmAll")
                                onClicked: root.confirmAllSelected()
                            }
                            Rectangle {   // automatic receipts toggle
                                implicitWidth: arRow.implicitWidth + 20; implicitHeight: 36; radius: 10
                                color: root.sel && root.sel.autoReceipts ? root.wbSuccessSubtle : "transparent"
                                border.color: root.sel && root.sel.autoReceipts ? root.wbSuccess : root.wbBorder; border.width: 1
                                RowLayout {
                                    id: arRow; anchors.centerIn: parent; spacing: 8
                                    Rectangle { width: 28; height: 16; radius: 8; color: root.sel && root.sel.autoReceipts ? root.wbSuccess : root.wbBorder
                                        Rectangle { width: 12; height: 12; radius: 6; y: 2; x: root.sel && root.sel.autoReceipts ? 14 : 2; color: "white" } }
                                    Text { textFormat: Text.PlainText; text: "Automatic receipts"; font.pixelSize: 12; color: root.wbTextSec }
                                }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.toggleAutoReceipts() }
                            }
                            WbButton {
                                visible: root.selQuiz && root.selUnscored > 0
                                primary: true
                                label: root.busy("sendScores") ? "Sending..." : "Send scores (" + root.selUnscored + ")"
                                active: !root.busy("sendScores")
                                onClicked: root.sendScoresSelected()
                            }
                            WbButton { label: "Export CSV"; active: root.selResponses.length > 0; onClicked: root.openCsv() }
                            WbButton { visible: !!(root.sel && root.sel.mine); label: root.showCoOwners ? "Hide co-owners" : "Co-owners" + ((root.sel && root.sel.coOwners && root.sel.coOwners.length) ? " (" + root.sel.coOwners.length + ")" : ""); onClicked: root.showCoOwners = !root.showCoOwners }
                        }
                        // ── co-owners panel ──
                        Rectangle {
                            visible: root.showCoOwners && !!(root.sel && root.sel.mine)
                            Layout.fillWidth: true
                            implicitHeight: coCol.implicitHeight + 24
                            radius: 12; color: root.wbSurfaceRaised; border.color: root.wbBorder; border.width: 1
                            ColumnLayout {
                                id: coCol; anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 12; spacing: 8
                                Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbTextSec
                                    text: "A co-owner can read every answer and send receipts. They need to give you their co-owner code (Identity in their WhisperBox). Access can't be taken back once given, and the list of co-owner addresses is public." }
                                Repeater {
                                    model: root.sel && root.sel.coOwners ? root.sel.coOwners : []
                                    Text { textFormat: Text.PlainText; text: "\u2022 " + modelData.address; font.pixelSize: 12; font.family: "monospace"; color: root.wbText }
                                }
                                RowLayout {
                                    Layout.fillWidth: true; spacing: 8
                                    InputBox { Layout.fillWidth: true; implicitHeight: 36
                                        TextField { id: coField; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                            font.pixelSize: 12; font.family: "monospace"; background: null; placeholderText: "Co-owner code (66 characters)" } }
                                    WbButton { label: root.busy("addCoOwner") ? "Adding..." : "Add co-owner"; active: !root.busy("addCoOwner") && coField.text.trim().length > 0
                                        onClicked: act("addCoOwner", [root.selectedId, coField.text.trim()], "Co-owner added - they can read answers now", function () { coField.text = ""; }) }
                                }
                            }
                        }
                        // several answers per person (ADR 0022): who sent how many, and how many you received
                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbTextSec
                            visible: !!(root.sel && root.sel.maxPerRespondent !== undefined && (root.sel.mine || root.sel.coOwner) && root.selResponses.length > 0)
                            text: {
                                if (!visible) return "";
                                var t = root.respondentTally(), parts = [];
                                for (var i = 0; i < Math.min(t.length, 6); i++)
                                    parts.push(root.shortAddr(t[i].respondent) + ": " + root.plural(t[i].answers, "answer", "answers") + (t[i].received ? " (" + t[i].received + " received)" : ""));
                                return root.plural(t.length, "person", "people") + " answered  \u00B7  " + parts.join(",  ") + (t.length > 6 ? ", ..." : "");
                            } }
                        Text { textFormat: Text.PlainText; visible: root.selQuiz; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbSuccess
                            text: "Quiz" + (root.selAvgScore ? "  \u00B7  average score " + root.selAvgScore : "") + "  \u00B7  scores and replies are sealed to each person - nobody else can read them" }
                        Text { textFormat: Text.PlainText
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbTextTert
                            visible: text.length > 0
                            text: {
                                var f = root.sel, parts = [];
                                if (!f) return "";
                                if (f.maxResponses) parts.push("Closes automatically at " + root.plural(f.maxResponses, "response", "responses"));
                                if (f.maxPerRespondent !== undefined) parts.push(f.maxPerRespondent > 1 ? "Up to " + f.maxPerRespondent + " answers per person" : "Any number of answers per person");
                                if (f.expiresAt) parts.push((f.status === "closed" ? "End date " : "Closes ") + root.fmtTime(f.expiresAt));
                                if (f.showResponseCount) parts.push("respondents see how many receipts you sent");
                                return parts.join("  ·  ");
                            }
                        }

                        // ── mode tabs + search ──
                        RowLayout {
                            Layout.fillWidth: true
                            visible: root.selResponses.length > 0
                            spacing: 6
                            Repeater {
                                model: [{ m: "summary", l: "Summary" }, { m: "question", l: "By question" }, { m: "table", l: "Table" }, { m: "one", l: "One by one" }]
                                Rectangle {
                                    property bool on: root.respMode === modelData.m
                                    implicitWidth: tabT.implicitWidth + 24; implicitHeight: 32; radius: 16
                                    color: on ? root.wbPrimarySubtle : "transparent"
                                    border.color: on ? root.wbPrimary : root.wbBorder; border.width: 1
                                    Text { id: tabT; textFormat: Text.PlainText; anchors.centerIn: parent; text: modelData.l; font.pixelSize: 12; font.weight: Font.DemiBold; color: parent.on ? root.wbPrimary : root.wbTextSec }
                                    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.respMode = modelData.m; if (modelData.m === "one") oneNav.forceActiveFocus(); } }
                                }
                            }
                            Item { Layout.fillWidth: true }
                            InputBox {
                                visible: root.respMode === "table" || root.respMode === "one" || root.respMode === "question"
                                implicitWidth: 220; implicitHeight: 32
                                TextField {
                                    anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10
                                    color: root.wbText; placeholderTextColor: root.wbTextTert; font.pixelSize: 12; background: null
                                    placeholderText: "Search answers or address"
                                    onTextChanged: { root.respFilter = text; root.respIndex = 0; }
                                }
                            }
                        }
                        Text { textFormat: Text.PlainText
                            visible: root.selResponses.length === 0
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 13; color: root.wbTextTert
                            text: "No responses yet. Share the link - answers arrive sealed and only this device can open them."
                        }
                        Text { textFormat: Text.PlainText
                            visible: root.selResponses.length > 0 && root.respMode !== "summary" && root.respList.length === 0
                            text: "Nothing matches \"" + root.respFilter + "\"."; font.pixelSize: 13; color: root.wbTextTert
                        }

                        // ── SUMMARY: one card per question ──
                        Repeater {
                            model: (root.respMode === "summary" && root.sel) ? root.sel.questions : []
                            Rectangle {
                                id: sumCard
                                Layout.fillWidth: true
                                implicitHeight: sumCol.implicitHeight + 28
                                radius: 12; color: root.wbSurfaceRaised; border.color: root.wbBorderSubtle; border.width: 1
                                property var sm: root.summaryFor(modelData)
                                ColumnLayout {
                                    id: sumCol
                                    anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 14
                                    spacing: 8
                                    RowLayout {
                                        Layout.fillWidth: true
                                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap; text: (index + 1) + ". " + modelData.text; font.pixelSize: 14; font.weight: Font.DemiBold; color: root.wbText }
                                        Text { textFormat: Text.PlainText; text: sumCard.sm.answered + " of " + root.selResponses.length + " answered"; font.pixelSize: 11; color: root.wbTextTert }
                                    }
                                    Repeater {
                                        model: sumCard.sm.rows
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 10
                                            Text { textFormat: Text.PlainText; Layout.preferredWidth: 160; elide: Text.ElideRight; text: modelData.label; font.pixelSize: 13; color: root.wbTextSec }
                                            Rectangle {
                                                Layout.fillWidth: true; implicitHeight: 14; radius: 7; color: root.wbSurface
                                                Rectangle { height: parent.height; radius: 7; width: Math.max(modelData.n ? 6 : 0, parent.width * modelData.w); color: root.wbPrimary }
                                            }
                                            Text { textFormat: Text.PlainText; Layout.preferredWidth: 78; horizontalAlignment: Text.AlignRight; text: modelData.n + "  (" + modelData.pct + "%)"; font.pixelSize: 12; color: root.wbText }
                                        }
                                    }
                                    Repeater {
                                        model: sumCard.sm.samples
                                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap; text: "“" + modelData + "”"; font.pixelSize: 13; color: root.wbTextSec }
                                    }
                                    Text { textFormat: Text.PlainText; visible: !!sumCard.sm.stat; text: sumCard.sm.stat || ""; font.pixelSize: 12; color: root.wbTextSec }
                                    Text { textFormat: Text.PlainText
                                        visible: !sumCard.sm.bars && sumCard.sm.answered > sumCard.sm.samples.length
                                        text: "+ " + (sumCard.sm.answered - sumCard.sm.samples.length) + " more - see Table or One by one"; font.pixelSize: 11; color: root.wbTextTert }
                                }
                            }
                        }

                        // ── BY QUESTION: pick a question, see every answer to it ──
                        ColumnLayout {
                            visible: root.respMode === "question" && root.selResponses.length > 0
                            Layout.fillWidth: true
                            spacing: 10
                            Flow {
                                Layout.fillWidth: true; spacing: 6
                                Repeater {
                                    model: root.sel ? root.sel.questions : []
                                    Rectangle {
                                        property bool on: index === root.byQIndex
                                        implicitWidth: Math.min(260, bqT.implicitWidth + 22); implicitHeight: 28; radius: 14
                                        color: on ? root.wbPrimarySubtle : "transparent"; border.color: on ? root.wbPrimary : root.wbBorder; border.width: 1
                                        Text { id: bqT; textFormat: Text.PlainText; anchors.centerIn: parent; width: Math.min(implicitWidth, 238); elide: Text.ElideRight
                                            text: (index + 1) + ". " + modelData.text; font.pixelSize: 11; color: parent.on ? root.wbPrimary : root.wbTextSec }
                                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.byQIndex = index }
                                    }
                                }
                            }
                            Repeater {
                                model: root.respMode === "question" ? root.byQList : []
                                Rectangle {
                                    Layout.fillWidth: true; implicitHeight: bqRow.implicitHeight + 18; radius: 10
                                    color: root.wbSurfaceRaised; border.color: root.wbBorderSubtle; border.width: 1
                                    RowLayout {
                                        id: bqRow; anchors.left: parent.left; anchors.right: parent.right; anchors.verticalCenter: parent.verticalCenter; anchors.margins: 12; spacing: 12
                                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap; text: modelData.text.length ? modelData.text : "(no answer)"
                                            font.pixelSize: 13; color: modelData.text.length ? root.wbText : root.wbTextTert }
                                        Text { textFormat: Text.PlainText; text: modelData.who; font.pixelSize: 11; font.family: "monospace"; color: root.wbTextTert }
                                    }
                                }
                            }
                        }

                        // ── TABLE: one row per response, one column per question ──
                        Rectangle {
                            visible: root.respMode === "table" && root.respList.length > 0
                            Layout.fillWidth: true
                            implicitHeight: Math.min(tableCol.implicitHeight + 2, 560)
                            radius: 12; color: root.wbSurfaceRaised; border.color: root.wbBorderSubtle; border.width: 1; clip: true
                            Flickable {
                                id: tableFlick
                                anchors.fill: parent; anchors.margins: 1
                                contentWidth: tableCol.implicitWidth; contentHeight: tableCol.implicitHeight
                                clip: true; boundsBehavior: Flickable.StopAtBounds
                                ScrollBar.horizontal: ScrollBar { policy: ScrollBar.AsNeeded }
                                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
                                Column {
                                    id: tableCol
                                    Row {   // header
                                        Repeater {
                                            model: ["#", "From", "When"].concat((root.sel ? root.sel.questions : []).map(function (q) { return q.text; })).concat(["Receipt"]).concat(root.selQuiz ? ["Score"] : [])
                                            Rectangle {
                                                width: index === 0 ? 44 : (index <= 2 ? 120 : 190); height: 36; color: root.wbSurface
                                                Text { textFormat: Text.PlainText; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; verticalAlignment: Text.AlignVCenter
                                                    elide: Text.ElideRight; text: modelData; font.pixelSize: 11; font.weight: Font.DemiBold; color: root.wbTextTert }
                                            }
                                        }
                                    }
                                    Repeater {
                                        model: root.respList
                                        Rectangle {
                                            id: trow
                                            property var r: modelData
                                            property int ri: index
                                            width: tableCol.width > 0 ? childrenRect.width : 0; height: 40
                                            color: trMa.containsMouse ? root.wbPrimarySubtle : (index % 2 ? root.wbSurfaceRaised : Qt.darker(root.wbSurfaceRaised, 1.08))
                                            Row {
                                                Repeater {
                                                    model: 3 + root.sel.questions.length + 1 + (root.selQuiz ? 1 : 0)
                                                    Item {
                                                        width: index === 0 ? 44 : (index <= 2 ? 120 : 190); height: 40
                                                        Text { textFormat: Text.PlainText; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                                                            font.pixelSize: 12; font.family: index === 1 ? "monospace" : ""
                                                            color: index === 3 + root.sel.questions.length ? (trow.r.confirmed ? root.wbSuccess : root.wbWarning) : root.wbText
                                                            text: {
                                                                if (index === 0) return String(trow.ri + 1) + (trow.r.edits > 0 ? " \u270E" : "");
                                                                if (index === 1) return root.shortAddr(trow.r.respondent) + (trow.r.answerNo ? "  #" + trow.r.answerNo : "") + (trow.r.verified === false ? "  (unverified)" : "");
                                                                if (index === 2) return Qt.formatDateTime(new Date(Number(trow.r.submittedAt || 0)), "d MMM hh:mm");
                                                                if (index === 3 + root.sel.questions.length) return trow.r.confirmed ? "sent" : "pending";
                                                                if (index === 4 + root.sel.questions.length) return root.scoreText(trow.r) + (trow.r.replies > 0 ? "  \u2709" : "");
                                                                var q = root.sel.questions[index - 3]; return root.answerText(q, root.answerOf(trow.r, q.id));
                                                            } }
                                                    }
                                                }
                                            }
                                            MouseArea { id: trMa; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                                onClicked: { root.respIndex = trow.ri; root.respMode = "one"; oneNav.forceActiveFocus(); } }
                                        }
                                    }
                                }
                            }
                        }
                        Text { textFormat: Text.PlainText; visible: root.respMode === "table" && root.respList.length > 0
                            text: "Click a row to open it.  Scroll sideways for more questions."; font.pixelSize: 11; color: root.wbTextTert }

                        // ── ONE BY ONE: a single response, prev / next / jump (arrow keys too) ──
                        FocusScope {
                            id: oneNav
                            visible: root.respMode === "one" && root.respList.length > 0
                            Layout.fillWidth: true
                            implicitHeight: oneCol.implicitHeight
                            readonly property int n: root.respList.length
                            readonly property int at: Math.max(0, Math.min(root.respIndex, n - 1))
                            readonly property var r: n > 0 ? root.respList[at] : null
                            function go(i) { if (n > 0) root.respIndex = Math.max(0, Math.min(n - 1, i)); }
                            Keys.onLeftPressed: go(at - 1)
                            Keys.onRightPressed: go(at + 1)
                            Keys.onPressed: function (ev) { if (ev.key === Qt.Key_Home) go(0); else if (ev.key === Qt.Key_End) go(n - 1); }
                            ColumnLayout {
                                id: oneCol
                                width: parent.width
                                spacing: 12
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: 8
                                    WbButton { label: "‹  Previous"; active: oneNav.at > 0; onClicked: { oneNav.go(oneNav.at - 1); oneNav.forceActiveFocus(); } }
                                    Item { Layout.fillWidth: true }
                                    Text { textFormat: Text.PlainText; text: "Response"; font.pixelSize: 13; color: root.wbTextSec }
                                    InputBox {
                                        implicitWidth: 56; implicitHeight: 32
                                        TextField {
                                            anchors.fill: parent; anchors.leftMargin: 6; anchors.rightMargin: 6
                                            horizontalAlignment: TextInput.AlignHCenter; color: root.wbText; font.pixelSize: 13; background: null
                                            text: String(oneNav.at + 1)
                                            validator: IntValidator { bottom: 1; top: Math.max(1, oneNav.n) }
                                            onAccepted: { oneNav.go(parseInt(text, 10) - 1); oneNav.forceActiveFocus(); }
                                        }
                                    }
                                    Text { textFormat: Text.PlainText; text: "of " + oneNav.n; font.pixelSize: 13; color: root.wbTextSec }
                                    Item { Layout.fillWidth: true }
                                    WbButton { label: "Next  ›"; active: oneNav.at < oneNav.n - 1; onClicked: { oneNav.go(oneNav.at + 1); oneNav.forceActiveFocus(); } }
                                }
                                Flow {   // quick jump strip (up to 60; beyond that, type the number)
                                    Layout.fillWidth: true
                                    visible: oneNav.n > 1 && oneNav.n <= 60
                                    spacing: 4
                                    Repeater {
                                        model: oneNav.n <= 60 ? oneNav.n : 0
                                        Rectangle {
                                            property var rr: root.respList[index]
                                            width: 30; height: 24; radius: 6
                                            color: index === oneNav.at ? root.wbPrimary : root.wbSurfaceRaised
                                            border.color: rr && rr.confirmed ? root.wbSuccess : root.wbBorder; border.width: 1
                                            Text { textFormat: Text.PlainText; anchors.centerIn: parent; text: String(index + 1); font.pixelSize: 10; color: index === oneNav.at ? "white" : root.wbTextSec }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { oneNav.go(index); oneNav.forceActiveFocus(); } }
                                        }
                                    }
                                }
                                Rectangle {
                                    Layout.fillWidth: true
                                    implicitHeight: oneCard.implicitHeight + 32
                                    radius: 14; color: root.wbSurfaceRaised; border.color: root.wbBorder; border.width: 1
                                    ColumnLayout {
                                        id: oneCard
                                        anchors.left: parent.left; anchors.right: parent.right; anchors.top: parent.top; anchors.margins: 16
                                        spacing: 14
                                        RowLayout {
                                            Layout.fillWidth: true
                                            spacing: 8
                                            // ADR 0019: an unsigned answer (older client, or someone claiming this address) proves nothing
                                            Text { textFormat: Text.PlainText; text: oneNav.r ? root.shortAddr(oneNav.r.respondent) + (oneNav.r.answerNo ? "  \u00B7  their answer #" + oneNav.r.answerNo : "") + (oneNav.r.verified === false ? "  unverified: not signed, could be from anyone" : "") : ""; font.pixelSize: 12; font.family: "monospace"; color: oneNav.r && oneNav.r.verified === false ? root.wbWarning : root.wbTextSec
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.copyText(oneNav.r.respondent, "Address") } }
                                            // ADR 0019: when the network had it (deadlines use that), or the sender's own claim
                                            Text { textFormat: Text.PlainText; text: root.answerTimeText(oneNav.r); font.pixelSize: 11; color: oneNav.r && oneNav.r.timeSkew ? root.wbWarning : root.wbTextTert }
                                            Item { Layout.fillWidth: true }
                                            Badge { visible: !!(oneNav.r && oneNav.r.outOf !== undefined); label: "Score " + root.scoreText(oneNav.r); fg: root.wbSuccess; bg: root.wbSuccessSubtle }
                                            Badge { visible: !!(oneNav.r && oneNav.r.replies > 0); label: oneNav.r ? root.plural(oneNav.r.replies, "reply", "replies") + " sent" : ""; fg: root.wbPrimary; bg: root.wbPrimarySubtle }
                                            Badge { visible: !!(oneNav.r && oneNav.r.edits > 0); label: "edited"; fg: root.wbAccent; bg: root.wbWarningSubtle }
                                            Badge { visible: !!(oneNav.r && oneNav.r.confirmed); label: "Receipt sent" }
                                            WbButton { visible: !!(oneNav.r && !oneNav.r.confirmed); implicitHeight: 28; label: "Send receipt"; onClicked: root.confirmOne(oneNav.r) }
                                        }
                                        Repeater {
                                            model: root.sel ? root.sel.questions : []
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 3
                                                Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap; text: (index + 1) + ". " + modelData.text; font.pixelSize: 12; color: root.wbTextTert }
                                                Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap
                                                    property string v: root.answerText(modelData, root.answerOf(oneNav.r, modelData.id))
                                                    property var ok: oneNav.r && oneNav.r.correct && modelData.id in oneNav.r.correct ? oneNav.r.correct[modelData.id] : null
                                                    text: (ok === true ? "\u2713 " : ok === false ? "\u2717 " : "") + (v.length ? v : "(no answer)"); font.pixelSize: 15
                                                    color: ok === true ? root.wbSuccess : ok === false ? root.wbError : (v.length ? root.wbText : root.wbTextTert) }
                                            }
                                        }
                                        RowLayout {   // private reply to this one answer
                                            Layout.fillWidth: true; spacing: 8
                                            visible: !!(oneNav.r && oneNav.r.replyPub)
                                            InputBox { Layout.fillWidth: true; implicitHeight: 36
                                                TextField { id: replyField; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                                    font.pixelSize: 13; background: null; placeholderText: "Reply privately - only this person can read it" } }
                                            WbButton { label: root.busy("replyToResponse") ? "Sending..." : "Send reply"; active: !root.busy("replyToResponse") && replyField.text.trim().length > 0
                                                onClicked: root.sendReply(oneNav.r.confirmationId, replyField.text.trim(), function () { replyField.text = ""; }) }
                                        }
                                    }
                                }
                                Text { textFormat: Text.PlainText; text: "Tip: ← → move between responses, Home / End jump to the first / last."; font.pixelSize: 11; color: root.wbTextTert }
                            }
                        }
                    }

                    // ══ RESPONDENT VIEW ══ (FormRespond.qml, shared with the respond module - ADR 0021)
                    FormRespond {
                        id: respond
                        Layout.fillWidth: true
                        visible: !!(root.sel && !root.sel.mine && !root.sel.coOwner)
                        form: root.sel
                        myAddress: root.myAddress
                        preview: !!root.previewDef
                        host: root
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
            SectionLabel { text: "YOUR CO-OWNER CODE" }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                InputBox {
                    Layout.fillWidth: true
                    implicitHeight: 38
                    Text { textFormat: Text.PlainText; anchors.fill: parent; anchors.leftMargin: 12; anchors.rightMargin: 12; verticalAlignment: Text.AlignVCenter
                        text: (root.st.identity && root.st.identity.pubHex) || "-"; font.pixelSize: 12; font.family: "monospace"; color: root.wbText; elide: Text.ElideMiddle }
                }
                WbButton { label: "Copy"; onClicked: root.copyText(root.st.identity ? root.st.identity.pubHex : "", "Co-owner code") }
            }
            Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbTextTert
                text: "Give this to a form's creator to become a co-owner: you'll be able to read that form's answers." }
            SectionLabel { text: "PASSPHRASE" }
            Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbTextTert
                text: root.idProtected
                      ? "Your key and saved answers are sealed with a passphrase. WhisperBox asks for it when it starts."
                      : "Optional: seal your key and saved answers with a passphrase, so other apps running as you can't read them. WhisperBox then asks for it when it starts. A forgotten passphrase can't be recovered." }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                InputBox {
                    Layout.fillWidth: true
                    visible: root.idProtected
                    implicitHeight: 38
                    TextField { id: passCur; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                font.pixelSize: 12; echoMode: TextInput.Password; background: null; placeholderText: "current passphrase" }
                }
                InputBox {
                    Layout.fillWidth: true
                    implicitHeight: 38
                    TextField { id: passNew; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                font.pixelSize: 12; echoMode: TextInput.Password; background: null; placeholderText: "new passphrase (8+ characters)" }
                }
                InputBox {
                    Layout.fillWidth: true
                    implicitHeight: 38
                    TextField { id: passAgain; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                font.pixelSize: 12; echoMode: TextInput.Password; background: null; placeholderText: "again" }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                WbButton { visible: root.idProtected; label: "Remove passphrase"; enabled: !root.busy("setPassphrase")
                           onClicked: root.setPass(passCur.text, "", "", function () { passCur.text = ""; }) }
                WbButton { label: root.idProtected ? "Change passphrase" : "Set passphrase"; enabled: !root.busy("setPassphrase") && String(passNew.text || "").length >= 8
                           onClicked: root.setPass(passCur.text, passNew.text, passAgain.text, function () { passCur.text = ""; passNew.text = ""; passAgain.text = ""; }) }
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
                WbButton { label: root.confirmImport ? "Really import?" : "Import"; active: String(keyField.text || "").length >= 64; onClicked: root.importKey() }
            }
            Text { textFormat: Text.PlainText;
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                font.pixelSize: 12
                color: root.wbWarning
                text: "Importing replaces this device's key. Forms you created with the current key can only be decrypted with it: the current key is kept as identity.json.prev in the data folder."
            }
            RowLayout {
                Layout.fillWidth: true
                Item { Layout.fillWidth: true }
                WbButton { label: "Done"; onClicked: root.showIdentity = false }
            }
        }
    }

    // ── Locked: a passphrase-protected identity (open-review 2026-11-03, FR-13) ──
    Rectangle {
        visible: !!root.lockedId
        z: 30
        anchors.fill: parent
        color: root.wbBg
        MouseArea { anchors.fill: parent }
        ColumnLayout {
            anchors.centerIn: parent
            width: Math.min(420, parent.width - 48)
            spacing: 12
            LockIcon { Layout.alignment: Qt.AlignHCenter }
            Text { textFormat: Text.PlainText; Layout.alignment: Qt.AlignHCenter; text: "WhisperBox is locked"; font.pixelSize: 20; font.weight: Font.Bold; color: root.wbText }
            Text { textFormat: Text.PlainText; Layout.fillWidth: true; horizontalAlignment: Text.AlignHCenter; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbTextSec
                text: "Your key (" + root.shortAddr(root.lockedId ? root.lockedId.address : "") + ") is sealed with a passphrase. Until you unlock, WhisperBox doesn't send, receive or open answers." }
            InputBox {
                Layout.fillWidth: true
                implicitHeight: 40
                TextField { id: unlockField; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                            font.pixelSize: 13; echoMode: TextInput.Password; background: null; placeholderText: "passphrase"
                            onAccepted: root.unlockFromField() }
            }
            WbButton { Layout.alignment: Qt.AlignHCenter; label: "Unlock"; enabled: !root.busy("unlock") && String(unlockField.text || "").length > 0
                       onClicked: root.unlockFromField() }
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

            RowLayout {
                Layout.fillWidth: true
                Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: root.editingFormId ? "Edit form" : (root.draftId ? "Edit draft" : "New form"); font.pixelSize: 22; font.weight: Font.Bold; color: root.wbText }
                Text { textFormat: Text.PlainText; visible: !!root.draftId; text: root.draftDirty ? "saving..." : "draft saved"; font.pixelSize: 11; color: root.wbTextTert }
            }

            Flickable {
                id: createFlick
                Layout.fillWidth: true
                Layout.fillHeight: true
                contentWidth: width
                contentHeight: createLoader.item ? createLoader.item.implicitHeight : 0
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

                // Re-created on open / reorder (rebuildBuilder): typed-in fields break their
                // bindings, so a fresh instance is the only way to show loaded / moved content.
                Loader {
                    id: createLoader
                    active: root.builderLive
                    sourceComponent: ColumnLayout {
                    id: createCol
                    width: createFlick.width - 10
                    spacing: 12

                    Text { textFormat: Text.PlainText; visible: !!root.editingFormId; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbAccent
                        text: "Editing a published form: everyone gets the new version. Answers already sent stay attached to their questions; removing a question hides its answers." }
                    SectionLabel { visible: !root.draftId && !root.editingFormId && root.builderEmpty(); text: "START FROM A TEMPLATE" }
                    Flow {
                        visible: !root.draftId && !root.editingFormId && root.builderEmpty()
                        Layout.fillWidth: true; spacing: 6
                        Repeater {
                            model: root.templates
                            Rectangle {
                                implicitWidth: tpT.implicitWidth + 22; implicitHeight: 30; radius: 15; color: "transparent"; border.color: root.wbBorder; border.width: 1
                                Text { id: tpT; textFormat: Text.PlainText; anchors.centerIn: parent; text: modelData.name; font.pixelSize: 12; color: root.wbTextSec }
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.useTemplate(index) }
                            }
                        }
                    }
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
                            property bool choice: d.type === "radioButtons" || d.type === "checkbox" || d.type === "dropdown"

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
                                    Repeater {   // per-question actions
                                        model: [{ l: "\u2191", tip: "up", on: dq.qi > 0 }, { l: "\u2193", tip: "down", on: dq.qi < root.draftQuestions.length - 1 },
                                                { l: "Copy", tip: "copy", on: true }, { l: "Remove", tip: "remove", on: root.draftQuestions.length > 1 }]
                                        Text { textFormat: Text.PlainText
                                            visible: modelData.on
                                            text: modelData.l; font.pixelSize: modelData.l.length === 1 ? 14 : 11; color: root.wbTextTert
                                            MouseArea { anchors.fill: parent; anchors.margins: -4; cursorShape: Qt.PointingHandCursor
                                                onClicked: modelData.tip === "up" ? root.moveDraftQuestion(dq.qi, -1) : modelData.tip === "down" ? root.moveDraftQuestion(dq.qi, 1)
                                                         : modelData.tip === "copy" ? root.duplicateDraftQuestion(dq.qi) : root.removeDraftQuestion(dq.qi) }
                                        }
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
                                InputBox {   // help text
                                    Layout.fillWidth: true; implicitHeight: 32; color: root.wbSurface
                                    TextField { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                        font.pixelSize: 12; background: null; placeholderText: "Help text (optional)"
                                        text: String(dq.d.help || ""); onTextChanged: if (text !== String(dq.d.help || "")) root.setDraft(dq.qi, "help", text) }
                                }
                                Flow {   // choice extras
                                    visible: dq.choice; Layout.fillWidth: true; spacing: 6
                                    Repeater {
                                        model: [{ k: "allowOther", l: "Allow \"Other\"" }, { k: "shuffleOptions", l: "Shuffle options" }]
                                        Rectangle {
                                            property bool on: !!dq.d[modelData.k]
                                            implicitWidth: xT.implicitWidth + 18; implicitHeight: 24; radius: 12
                                            color: on ? root.wbPrimarySubtle : "transparent"; border.color: on ? root.wbPrimary : root.wbBorder; border.width: 1
                                            Text { id: xT; textFormat: Text.PlainText; anchors.centerIn: parent; text: (parent.on ? "\u2713 " : "") + modelData.l; font.pixelSize: 11; color: parent.on ? root.wbPrimary : root.wbTextSec }
                                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setDraft(dq.qi, modelData.k, !parent.on) }
                                        }
                                    }
                                }
                                ColumnLayout {   // scale settings
                                    visible: dq.d.type === "scale"; Layout.fillWidth: true; spacing: 6
                                    Flow {
                                        Layout.fillWidth: true; spacing: 6
                                        Repeater {
                                            model: [{ l: "0", k: "min", v: 0 }, { l: "1", k: "min", v: 1 }, { l: "to 3", k: "max", v: 3 }, { l: "4", k: "max", v: 4 }, { l: "5", k: "max", v: 5 },
                                                    { l: "7", k: "max", v: 7 }, { l: "10", k: "max", v: 10 }, { l: "Numbers", k: "style", v: "numbers" }, { l: "Stars \u2605", k: "style", v: "stars" }]
                                            Rectangle {
                                                property var cur: dq.d[modelData.k] === undefined ? (modelData.k === "min" ? 1 : modelData.k === "max" ? 5 : "numbers") : dq.d[modelData.k]
                                                property bool on: cur === modelData.v
                                                implicitWidth: sT.implicitWidth + 16; implicitHeight: 24; radius: 12
                                                color: on ? root.wbPrimarySubtle : "transparent"; border.color: on ? root.wbPrimary : root.wbBorder; border.width: 1
                                                Text { id: sT; textFormat: Text.PlainText; anchors.centerIn: parent; text: (modelData.k === "min" && modelData.v === 0 ? "from " : "") + modelData.l; font.pixelSize: 11; color: parent.on ? root.wbPrimary : root.wbTextSec }
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.setDraft(dq.qi, modelData.k, modelData.v) }
                                            }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        Repeater {
                                            model: [{ k: "minLabel", p: "Label for the low end (optional)" }, { k: "maxLabel", p: "Label for the high end (optional)" }]
                                            InputBox { Layout.fillWidth: true; implicitHeight: 32; color: root.wbSurface
                                                TextField { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                                    font.pixelSize: 12; background: null; placeholderText: modelData.p
                                                    text: String(dq.d[modelData.k] || ""); onTextChanged: if (text !== String(dq.d[modelData.k] || "")) root.setDraft(dq.qi, modelData.k, text) } }
                                        }
                                    }
                                }
                                RowLayout {   // number limits
                                    visible: dq.d.type === "number"; Layout.fillWidth: true; spacing: 6
                                    Repeater {
                                        model: [{ k: "numMin", p: "Minimum (optional)" }, { k: "numMax", p: "Maximum (optional)" }]
                                        InputBox { Layout.fillWidth: true; implicitHeight: 32; color: root.wbSurface
                                            TextField { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                                font.pixelSize: 12; background: null; placeholderText: modelData.p
                                                text: String(dq.d[modelData.k] || ""); onTextChanged: if (text !== String(dq.d[modelData.k] || "")) root.setDraft(dq.qi, modelData.k, text) } }
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
                                // ── quiz: the right answer + points ──
                                ColumnLayout {
                                    visible: root.draftQuiz && root.quizScorable(dq.d.type)
                                    Layout.fillWidth: true; spacing: 6
                                    Text { textFormat: Text.PlainText; text: "RIGHT ANSWER"; font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 0.8; color: root.wbSuccess }
                                    Flow {   // choices / yes-no: tap the right one(s)
                                        visible: dq.choice || dq.d.type === "boolean"
                                        Layout.fillWidth: true; spacing: 6
                                        Repeater {
                                            model: dq.d.type === "boolean" ? ["Yes", "No"] : root.draftOptions(dq.d)
                                            Rectangle {
                                                property bool on: dq.d.type === "boolean" ? dq.d.correct === (index === 0)
                                                                : dq.d.type === "checkbox" ? (dq.d.correctSet || []).indexOf(index) >= 0 : dq.d.correct === index
                                                implicitWidth: caT.implicitWidth + 18; implicitHeight: 24; radius: 12
                                                color: on ? root.wbSuccessSubtle : "transparent"; border.color: on ? root.wbSuccess : root.wbBorder; border.width: 1
                                                Text { id: caT; textFormat: Text.PlainText; anchors.centerIn: parent; text: (parent.on ? "\u2713 " : "") + modelData; font.pixelSize: 11; color: parent.on ? root.wbSuccess : root.wbTextSec }
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                                    onClicked: dq.d.type === "checkbox" ? root.toggleCorrectSet(dq.qi, index)
                                                             : root.setDraft(dq.qi, "correct", dq.d.type === "boolean" ? index === 0 : (parent.on ? -1 : index)) }
                                            }
                                        }
                                    }
                                    RowLayout {
                                        Layout.fillWidth: true; spacing: 6
                                        InputBox {   // typed answers: accepted spellings / the number
                                            visible: !dq.choice && dq.d.type !== "boolean"
                                            Layout.fillWidth: true; implicitHeight: 32; color: root.wbSurface
                                            TextField { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                                font.pixelSize: 12; background: null
                                                readonly property string k: dq.d.type === "scale" || dq.d.type === "number" ? "correctNum" : "accepted"
                                                placeholderText: k === "correctNum" ? "The right number" : "Accepted answers, comma-separated (case doesn't matter)"
                                                text: String(dq.d[k] || ""); onTextChanged: if (text !== String(dq.d[k] || "")) root.setDraft(dq.qi, k, text) }
                                        }
                                        InputBox {
                                            Layout.preferredWidth: 90; implicitHeight: 32; color: root.wbSurface
                                            TextField { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                                font.pixelSize: 12; background: null; placeholderText: "1 point"
                                                text: String(dq.d.points || ""); onTextChanged: if (text !== String(dq.d.points || "")) root.setDraft(dq.qi, "points", text) }
                                        }
                                        Text { textFormat: Text.PlainText; text: "points"; font.pixelSize: 11; color: root.wbTextTert }
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
                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.draftRestrict = modelData.r; if (modelData.r) root.draftAnonymous = false; } }
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
                    SectionLabel { text: "LIMITS & TIMING (OPTIONAL)" }
                    RowLayout {
                        Layout.fillWidth: true
                        spacing: 10
                        ColumnLayout {
                            spacing: 4
                            Text { textFormat: Text.PlainText; text: "Close after this many answers"; font.pixelSize: 11; color: root.wbTextTert }
                            InputBox { implicitWidth: 120; implicitHeight: 36
                                TextField { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                    font.pixelSize: 13; background: null; placeholderText: "no limit"; validator: IntValidator { bottom: 1 }
                                    text: root.draftMax; onTextChanged: root.draftMax = text } }
                        }
                        ColumnLayout {
                            Layout.fillWidth: true
                            spacing: 4
                            Text { textFormat: Text.PlainText; text: "Close at (yyyy-MM-dd HH:mm)"; font.pixelSize: 11; color: root.wbTextTert }
                            InputBox { Layout.fillWidth: true; implicitHeight: 36
                                TextField { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                                    font.pixelSize: 13; background: null; placeholderText: "no end date"
                                    text: root.draftCloseAt; onTextChanged: root.draftCloseAt = text } }
                        }
                    }
                    Rectangle {
                        implicitWidth: scT.implicitWidth + 22; implicitHeight: 30; radius: 15
                        color: root.draftShowCount ? root.wbPrimarySubtle : "transparent"
                        border.color: root.draftShowCount ? root.wbPrimary : root.wbBorder; border.width: 1
                        Text { id: scT; textFormat: Text.PlainText; anchors.centerIn: parent; text: (root.draftShowCount ? "\u2713 " : "") + "Show respondents how many answers came in"; font.pixelSize: 12; color: root.draftShowCount ? root.wbPrimary : root.wbTextSec }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.draftShowCount = !root.draftShowCount }
                    }
                    Rectangle {
                        implicitWidth: shT.implicitWidth + 22; implicitHeight: 30; radius: 15
                        color: root.draftShuffle ? root.wbPrimarySubtle : "transparent"
                        border.color: root.draftShuffle ? root.wbPrimary : root.wbBorder; border.width: 1
                        Text { id: shT; textFormat: Text.PlainText; anchors.centerIn: parent; text: (root.draftShuffle ? "\u2713 " : "") + "Shuffle question order for each respondent"; font.pixelSize: 12; color: root.draftShuffle ? root.wbPrimary : root.wbTextSec }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.draftShuffle = !root.draftShuffle }
                    }
                    Rectangle {
                        implicitWidth: aeT.implicitWidth + 22; implicitHeight: 30; radius: 15
                        color: root.draftAllowEdits ? root.wbPrimarySubtle : "transparent"
                        border.color: root.draftAllowEdits ? root.wbPrimary : root.wbBorder; border.width: 1
                        Text { id: aeT; textFormat: Text.PlainText; anchors.centerIn: parent; font.pixelSize: 12; color: root.draftAllowEdits ? root.wbPrimary : root.wbTextSec
                            text: (root.draftAllowEdits ? "\u2713 " : "") + "Let people edit their answer for 15 minutes (until you send a receipt)" }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.draftAllowEdits = !root.draftAllowEdits; if (root.draftAllowEdits) root.draftMulti = false; } }
                    }
                    RowLayout {
                        spacing: 10
                        Rectangle {
                            implicitWidth: muT.implicitWidth + 22; implicitHeight: 30; radius: 15
                            color: root.draftMulti ? root.wbPrimarySubtle : "transparent"
                            border.color: root.draftMulti ? root.wbPrimary : root.wbBorder; border.width: 1
                            Text { id: muT; textFormat: Text.PlainText; anchors.centerIn: parent; font.pixelSize: 12; color: root.draftMulti ? root.wbPrimary : root.wbTextSec
                                text: (root.draftMulti ? "\u2713 " : "") + "Let each person send several answers (feedback, bug reports, ideas)" }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.draftMulti = !root.draftMulti; if (root.draftMulti) root.draftAllowEdits = false; } }
                        }
                        Text { visible: root.draftMulti; textFormat: Text.PlainText; text: "up to"; font.pixelSize: 12; color: root.wbTextTert }
                        InputBox { visible: root.draftMulti; implicitWidth: 90; implicitHeight: 30
                            TextField { anchors.fill: parent; anchors.leftMargin: 8; anchors.rightMargin: 8; color: root.wbText; placeholderTextColor: root.wbTextTert
                                font.pixelSize: 12; background: null; placeholderText: "no limit"; validator: IntValidator { bottom: 2 }
                                text: root.draftPerPerson; onTextChanged: root.draftPerPerson = text } }
                    }
                    Rectangle {
                        implicitWidth: anT.implicitWidth + 22; implicitHeight: 30; radius: 15
                        color: root.draftAnonymous ? root.wbPrimarySubtle : "transparent"
                        border.color: root.draftAnonymous ? root.wbPrimary : root.wbBorder; border.width: 1
                        Text { id: anT; textFormat: Text.PlainText; anchors.centerIn: parent; font.pixelSize: 12; color: root.draftAnonymous ? root.wbPrimary : root.wbTextSec
                            text: (root.draftAnonymous ? "\u2713 " : "") + "Anonymous answers (you can't link them to anyone's address)" }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: { root.draftAnonymous = !root.draftAnonymous; if (root.draftAnonymous) root.draftRestrict = false; } }
                    }
                    Rectangle {   // quiz mode
                        implicitWidth: qzT.implicitWidth + 20; implicitHeight: 30; radius: 15
                        color: root.draftQuiz ? root.wbSuccessSubtle : "transparent"
                        border.color: root.draftQuiz ? root.wbSuccess : root.wbBorder; border.width: 1
                        Text { id: qzT; textFormat: Text.PlainText; anchors.centerIn: parent; font.pixelSize: 12; color: root.draftQuiz ? root.wbSuccess : root.wbTextSec
                            text: (root.draftQuiz ? "\u2713 " : "") + "Quiz (mark right answers, send each person their score privately)" }
                        MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.draftQuiz = !root.draftQuiz }
                    }
                    SectionLabel { text: "THANK-YOU MESSAGE (OPTIONAL)" }
                    InputBox {
                        Layout.fillWidth: true; implicitHeight: 36
                        TextField { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                            font.pixelSize: 13; background: null; placeholderText: "Shown to respondents after they send their answers"
                            text: root.draftThankYou; onTextChanged: root.draftThankYou = text }
                    }
                    Text { textFormat: Text.PlainText;
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                        font.pixelSize: 12
                        color: root.wbTextTert
                        text: "The form (title, questions, who may answer) is public on the network. Answers are encrypted to this form's own key. Drafts stay on this device."
                    }
                }
                }
            }

            RowLayout {   // schedule
                Layout.fillWidth: true
                visible: root.draftScheduling
                spacing: 8
                Text { textFormat: Text.PlainText; text: "Publish at"; font.pixelSize: 12; color: root.wbTextSec }
                InputBox { Layout.fillWidth: true; implicitHeight: 36
                    TextField { anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 10; color: root.wbText; placeholderTextColor: root.wbTextTert
                        font.pixelSize: 13; background: null; placeholderText: "yyyy-MM-dd HH:mm"; text: root.draftPublishAt; onTextChanged: root.draftPublishAt = text } }
                WbButton { primary: true; label: "Schedule"; onClicked: root.doSchedule() }
            }
            Text { textFormat: Text.PlainText; visible: root.draftScheduling; Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 11; color: root.wbTextTert
                text: "There is no server: the form goes out when WhisperBox is running on this computer at (or after) that time." }

            RowLayout {
                Layout.fillWidth: true
                WbButton { visible: !!root.draftId && !root.editingFormId; label: root.confirmDiscard ? "Really delete?" : "Delete draft"; danger: true; onClicked: root.discardDraft() }
                Item { Layout.fillWidth: true }
                WbButton { label: "Close"; onClicked: root.closeBuilder() }
                WbButton { label: "Preview"; onClicked: root.openPreview() }
                WbButton { visible: !root.editingFormId; label: "Save draft"; onClicked: root.saveCurrentDraftNow() }
                WbButton { visible: !root.editingFormId; label: root.draftScheduling ? "Don't schedule" : "Schedule..."; onClicked: root.draftScheduling = !root.draftScheduling }
                WbButton { visible: !root.editingFormId; primary: true; label: root.busy("createForm") ? "Publishing..." : "Publish now"; active: !root.busy("createForm"); onClicked: root.doCreate() }
                WbButton { visible: !!root.editingFormId; primary: true; label: root.busy("updateForm") ? "Saving..." : "Save changes"; active: !root.busy("updateForm"); onClicked: root.doUpdate() }
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
