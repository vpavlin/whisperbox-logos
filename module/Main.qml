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
    property bool showHidden: false   // sidebar: expand the "Hidden" section
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
    // 0.3.2 builder extras + responses viewer
    property string draftId: ""            // saved draft being edited ("" = not saved yet)
    property string draftMax: ""           // max responses (text field)
    property string draftCloseAt: ""       // "yyyy-MM-dd HH:mm" or ""
    property bool draftShowCount: false
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
        { t: "boolean", label: "Yes / No" }
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
    readonly property var watchedIds: (st.watched || [])
    readonly property var creatorView: st.creatorView || null
    readonly property var diag: st.diagnostics || ({})
    readonly property string myAddress: (st.identity && st.identity.address) ? st.identity.address : ""
    // Core can't persist (no writable folder): forms + identity would be lost on restart.
    readonly property bool storageBad: !!(st.storage && st.storage.ok === false)
    readonly property string storageNote: (st.storage && st.storage.note) ? st.storage.note : ""
    readonly property bool nodeReady: !!st.nodeReady
    readonly property var sel: forms[selectedId] || null
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
        var rs = root.selResponses, t = normType(q.type);
        var labels = t === "boolean" ? ["Yes", "No"] : (q.options || []);
        if (t === "radioButtons" || t === "checkbox" || t === "boolean") {
            var counts = [], answered = 0;
            for (var o = 0; o < labels.length; o++) counts.push(0);
            for (var i = 0; i < rs.length; i++) {
                var v = answerOf(rs[i], q.id), hit = false;
                if (t === "boolean") { if (v === true) { counts[0]++; hit = true; } else if (v === false) { counts[1]++; hit = true; } }
                else { var l = isList(v) ? toList(v) : (typeof v === "number" ? [v] : []);
                       for (var j = 0; j < l.length; j++) if (l[j] >= 0 && l[j] < counts.length) { counts[l[j]]++; hit = true; } }
                if (hit) answered++;
            }
            var rows = [], max = 1;
            for (var c = 0; c < counts.length; c++) max = Math.max(max, counts[c]);
            for (var d = 0; d < labels.length; d++) rows.push({ label: String(labels[d]), n: counts[d], pct: answered ? Math.round(100 * counts[d] / answered) : 0, w: counts[d] / max });
            return { bars: true, rows: rows, answered: answered, samples: [] };
        }
        var texts = [];
        for (var x = rs.length - 1; x >= 0; x--) { var s = answerText(q, answerOf(rs[x], q.id)); if (s) texts.push(s); }
        return { bars: false, rows: [], answered: texts.length, samples: texts.slice(0, 5) };
    }
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
        return (s === "text" || s === "textarea" || s === "radioButtons" || s === "checkbox" || s === "boolean") ? s : "text";
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
        var one = function (x) {
            if (typeof x === "boolean") return x ? "Yes" : "No";
            return (typeof x === "number" && opts[x] !== undefined) ? String(opts[x]) : String(x);
        };
        if (isList(v)) { var parts = []; for (var i = 0; i < v.length; i++) parts.push(one(v[i])); return parts.join(", "); }
        return one(v);
    }

    // Sidebar rows: section headers + form rows, grouped by relationship.
    readonly property var sidebarRows: {
        var mine = [], answered = [], open = [], hidden = [], rows = [];
        var ids = Object.keys(root.forms);
        ids.sort(function (a, b) { return (root.forms[b].createdAt || 0) - (root.forms[a].createdAt || 0); });
        for (var i = 0; i < ids.length; i++) {
            var f = root.forms[ids[i]];
            // No public directory: a form is listed only if it's yours, you answered it, or you
            // opened its link. Everything else the node relays stays invisible (anyone can
            // publish, so a public list would be a spam channel).
            if (f.hidden) { hidden.push(f.id); continue; }   // local hide (Hide button)
            if (f.mine) mine.push(f.id);
            else if (f.mySubmitted) answered.push(f.id);
            else if (root.watchedIds.indexOf(f.id) >= 0) open.push(f.id);
        }
        var add = function (label, list, kind) {
            if (list.length === 0) return;
            rows.push({ kind: "h", label: label + "  " + list.length });
            for (var k = 0; k < list.length; k++) rows.push({ kind: kind, id: list[k] });
        };
        if (root.drafts.length > 0) {
            rows.push({ kind: "h", label: "DRAFTS  " + root.drafts.length });
            for (var dd = 0; dd < root.drafts.length; dd++) rows.push({ kind: "d", id: root.drafts[dd].id, draft: root.drafts[dd] });
        }
        add("WAITING FOR SYNC", root.pendingForms, "p");
        add("MY FORMS", mine, "f");
        add("ANSWERED", answered, "f");
        add("OPENED FROM LINKS", open, "f");
        if (hidden.length > 0) {
            rows.push({ kind: "hh", label: "HIDDEN  " + hidden.length + "   \u00B7  " + (root.showHidden ? "hide" : "show") });
            if (root.showHidden) for (var h = 0; h < hidden.length; h++) rows.push({ kind: "f", id: hidden[h] });
        }
        return rows;
    }

    // ── actions ──
    function selectForm(id) {
        root.selectedId = id; root.showErrors = false; root.respIndex = 0; root.respFilter = "";
        restoreAnswerDraft();
    }
    // Half-filled answers saved while typing come back (crash, restart, switching forms).
    function restoreAnswerDraft() {
        var f = root.forms[root.selectedId], a = {};
        if (f && f.answerDraft && !f.mySubmitted) for (var i = 0; i < f.answerDraft.length; i++) a[f.answerDraft[i].questionId] = f.answerDraft[i].value;
        root.answers = a;
    }
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
    function setAnswer(qid, v) { var a = Object.assign({}, root.answers); a[qid] = v; root.answers = a; answerDraftTimer.restart(); }
    function saveAnswerDraftNow() {
        if (!root.sel || root.sel.mine || root.sel.mySubmitted) return;
        var arr = [];
        for (var k in root.answers) if (root.answers.hasOwnProperty(k)) arr.push({ questionId: k, value: root.answers[k] });
        callVia("saveAnswerDraft", [root.sel.id, JSON.stringify(arr)], function () {});
    }
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
            if (v === undefined) v = normType(q.type) === "checkbox" ? [] : ((normType(q.type) === "radioButtons" || normType(q.type) === "boolean") ? null : "");
            arr.push({ questionId: q.id, value: v });
        }
        answerDraftTimer.stop();   // the core drops the answer draft on submit
        act("submitResponse", [f.id, JSON.stringify(arr)], "Response sealed and sent", function () {
            root.answers = ({}); root.showErrors = false;
        });
    }
    function confirmResponse(addr) { act("confirmResponse", [root.selectedId, addr], "Receipt sent"); }
    function toggleHidden() {
        var f = root.sel; if (!f) return;
        var hide = !f.hidden;
        act(hide ? "hideForm" : "unhideForm", [f.id], hide ? "Hidden - find it under Hidden in the sidebar" : "Back in your lists", function () {
            if (hide && !root.showHidden) root.selectedId = "";
        });
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
    function importKey() {
        var k = String(keyField.text || "").trim().replace(/^0x/, "");
        act("importIdentity", [k], "Identity imported", function () { keyField.text = ""; });
    }

    // ── create-form builder (drafts autosave; publish now / schedule) ──
    function rebuildBuilder() { root.builderLive = false; Qt.callLater(function () { root.builderLive = true; }); }
    function resetBuilder() {
        root.draftId = ""; root.draftTitle = ""; root.draftDescription = ""; root.draftRestrict = false; root.draftAllowList = "";
        root.draftQuestions = [{ type: "text", text: "", required: true, optionsText: "" }];
        root.draftMax = ""; root.draftCloseAt = ""; root.draftShowCount = false; root.draftPublishAt = ""; root.draftScheduling = false;
    }
    function openCreate() { resetBuilder(); rebuildBuilder(); root.draftDirty = false; root.showCreate = true; }
    function loadBuilder(b) {
        resetBuilder();
        root.draftTitle = b.title || ""; root.draftDescription = b.description || "";
        root.draftQuestions = (b.questions && b.questions.length) ? b.questions : root.draftQuestions;
        root.draftRestrict = !!b.restrict; root.draftAllowList = b.allowList || "";
        root.draftMax = b.max || ""; root.draftCloseAt = b.closeAt || ""; root.draftShowCount = !!b.showCount;
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
            qs.push({ type: normType(q.type), text: q.text || "", required: !!q.required, optionsText: (q.options || []).join("\n") });
        }
        loadBuilder({ title: (f.title || "") + " (copy)", description: f.description || "", questions: qs,
                      restrict: !!(f.whitelist && f.whitelist.type === "addresses"), allowList: (f.whitelist && f.whitelist.value || "").split(",").join("\n"),
                      max: f.maxResponses ? String(f.maxResponses) : "", showCount: !!f.showResponseCount });
        rebuildBuilder(); root.draftDirty = true; root.showCreate = true;
    }
    function addDraftQuestion() { root.draftQuestions = root.draftQuestions.concat([{ type: "text", text: "", required: false, optionsText: "" }]); }
    function removeDraftQuestion(i) { var a = root.draftQuestions.slice(); a.splice(i, 1); root.draftQuestions = a; rebuildBuilder(); }
    function moveDraftQuestion(i, d) {
        var j = i + d; if (j < 0 || j >= root.draftQuestions.length) return;
        var a = root.draftQuestions.slice(); var t = a[i]; a[i] = a[j]; a[j] = t; root.draftQuestions = a; rebuildBuilder();
    }
    function duplicateDraftQuestion(i) {
        var a = root.draftQuestions.slice(); a.splice(i + 1, 0, Object.assign({}, a[i])); root.draftQuestions = a; rebuildBuilder();
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
        restrict: root.draftRestrict, allowList: root.draftAllowList, max: root.draftMax, closeAt: root.draftCloseAt, showCount: root.draftShowCount })
    onBuilderStateChanged: if (root.showCreate) root.draftDirty = true
    // -> { ok, def, error }. strict=false never fails (autosave of a half-done form).
    function buildDef(strict) {
        var err = function (m) { return { ok: false, error: m }; };
        var title = root.draftTitle.trim();
        if (strict && !title) return err("Give the form a title");
        var qs = [];
        for (var i = 0; i < root.draftQuestions.length; i++) {
            var d = root.draftQuestions[i], text = String(d.text || "").trim();
            if (!text) continue;
            var q = { id: "q" + (qs.length + 1), type: d.type, text: text, required: !!d.required };
            if (d.type === "radioButtons" || d.type === "checkbox") {
                q.options = draftOptions(d);
                if (strict && q.options.length < 2) return err("\"" + text + "\" needs at least two options");
            }
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
        if (publishAt) d.publishAt = publishAt;
        callVia("saveDraft", [JSON.stringify(d)], function (r) {
            if (r && r.ok) { root.draftId = r.draftId; root.draftDirty = false; if (cb) cb(r); }
        });
    }
    Timer { id: draftAutosave; interval: 2500; repeat: true; running: root.showCreate && root.draftDirty
            onTriggered: if (!root.builderEmpty()) root.saveCurrentDraft(null) }
    Timer { id: answerDraftTimer; interval: 900; onTriggered: root.saveAnswerDraftNow() }
    function closeBuilder() {
        if (root.draftDirty && !builderEmpty()) saveCurrentDraft(null, function () { toast("Saved as a draft"); });
        else if (root.draftId && builderEmpty()) callVia("deleteDraft", [root.draftId], function () {});
        root.showCreate = false;
    }
    function discardDraft() {
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
                        property bool isHead: modelData.kind === "h" || modelData.kind === "hh"
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
                            visible: modelData.kind === "hh"
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.showHidden = !root.showHidden
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
                        WbButton { visible: !!root.sel; label: root.sel && root.sel.hidden ? "Unhide" : "Hide"; enabled: !root.busy(root.sel && root.sel.hidden ? "unhideForm" : "hideForm"); onClicked: root.toggleHidden() }
                        WbButton { visible: !!root.sel; label: "Duplicate"; onClicked: root.duplicateSelected() }
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

                        // ── toolbar: lifecycle + receipts ──
                        Flow {
                            Layout.fillWidth: true
                            spacing: 8
                            WbButton {
                                visible: !!(root.sel && root.sel.status === "open")
                                label: "Close form"; danger: true
                                onClicked: root.closeSelected()
                            }
                            WbButton {
                                // not when it closed at its answer limit or end date (it would just close again)
                                visible: !!(root.sel && root.sel.status === "closed" && !(root.sel.maxResponses && root.selResponses.length >= root.sel.maxResponses)
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
                            WbButton { label: "Export CSV"; active: root.selResponses.length > 0; onClicked: root.openCsv() }
                        }
                        Text { textFormat: Text.PlainText
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbTextTert
                            visible: text.length > 0
                            text: {
                                var f = root.sel, parts = [];
                                if (!f) return "";
                                if (f.maxResponses) parts.push("Closes automatically at " + root.plural(f.maxResponses, "response", "responses"));
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
                                model: [{ m: "summary", l: "Summary" }, { m: "table", l: "Table" }, { m: "one", l: "One by one" }]
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
                                visible: root.respMode !== "summary"
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
                                        model: sumCard.sm.bars ? [] : sumCard.sm.samples
                                        Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap; text: "“" + modelData + "”"; font.pixelSize: 13; color: root.wbTextSec }
                                    }
                                    Text { textFormat: Text.PlainText
                                        visible: !sumCard.sm.bars && sumCard.sm.answered > sumCard.sm.samples.length
                                        text: "+ " + (sumCard.sm.answered - sumCard.sm.samples.length) + " more - see Table or One by one"; font.pixelSize: 11; color: root.wbTextTert }
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
                                            model: ["#", "From", "When"].concat((root.sel ? root.sel.questions : []).map(function (q) { return q.text; })).concat(["Receipt"])
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
                                                    model: 3 + root.sel.questions.length + 1
                                                    Item {
                                                        width: index === 0 ? 44 : (index <= 2 ? 120 : 190); height: 40
                                                        Text { textFormat: Text.PlainText; anchors.fill: parent; anchors.leftMargin: 10; anchors.rightMargin: 8; verticalAlignment: Text.AlignVCenter; elide: Text.ElideRight
                                                            font.pixelSize: 12; font.family: index === 1 ? "monospace" : ""
                                                            color: index === 3 + root.sel.questions.length ? (trow.r.confirmed ? root.wbSuccess : root.wbWarning) : root.wbText
                                                            text: {
                                                                if (index === 0) return String(trow.ri + 1);
                                                                if (index === 1) return root.shortAddr(trow.r.respondent);
                                                                if (index === 2) return Qt.formatDateTime(new Date(Number(trow.r.submittedAt || 0)), "d MMM hh:mm");
                                                                if (index === 3 + root.sel.questions.length) return trow.r.confirmed ? "sent" : "pending";
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
                                            Text { textFormat: Text.PlainText; text: oneNav.r ? root.shortAddr(oneNav.r.respondent) : ""; font.pixelSize: 12; font.family: "monospace"; color: root.wbTextSec
                                                MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.copyText(oneNav.r.respondent, "Address") } }
                                            Text { textFormat: Text.PlainText; text: oneNav.r ? root.fmtTime(oneNav.r.submittedAt) : ""; font.pixelSize: 11; color: root.wbTextTert }
                                            Item { Layout.fillWidth: true }
                                            Badge { visible: !!(oneNav.r && oneNav.r.confirmed); label: "Receipt sent" }
                                            WbButton { visible: !!(oneNav.r && !oneNav.r.confirmed); implicitHeight: 28; label: "Send receipt"; onClicked: root.confirmResponse(oneNav.r.respondent) }
                                        }
                                        Repeater {
                                            model: root.sel ? root.sel.questions : []
                                            ColumnLayout {
                                                Layout.fillWidth: true
                                                spacing: 3
                                                Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap; text: (index + 1) + ". " + modelData.text; font.pixelSize: 12; color: root.wbTextTert }
                                                Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap
                                                    property string v: root.answerText(modelData, root.answerOf(oneNav.r, modelData.id))
                                                    text: v.length ? v : "(no answer)"; font.pixelSize: 15; color: v.length ? root.wbText : root.wbTextTert }
                                            }
                                        }
                                    }
                                }
                                Text { textFormat: Text.PlainText; text: "Tip: ← → move between responses, Home / End jump to the first / last."; font.pixelSize: 11; color: root.wbTextTert }
                            }
                        }
                    }

                    // ══ RESPONDENT VIEW ══
                    ColumnLayout {
                        Layout.fillWidth: true
                        visible: !!(root.sel && !root.sel.mine)
                        spacing: 14

                        Text { textFormat: Text.PlainText
                            Layout.fillWidth: true; wrapMode: Text.WordWrap; font.pixelSize: 12; color: root.wbTextTert
                            visible: text.length > 0
                            text: {
                                var f = root.sel, parts = [];
                                if (!f) return "";
                                if (f.showResponseCount) parts.push(root.plural((f.confirmations || []).length, "response", "responses") + " received so far");
                                if (f.maxResponses) parts.push("limited to " + f.maxResponses);
                                if (f.expiresAt) parts.push((f.status === "closed" ? "closed " : "closes ") + root.fmtTime(f.expiresAt));
                                if (f.answerDraft && !f.mySubmitted) parts.push("your unsent answers were restored");
                                return parts.join("  ·  ");
                            }
                        }
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

                        // What I answered (a private local copy - the sent answers are sealed to the creator)
                        ColumnLayout {
                            Layout.fillWidth: true
                            visible: !!(root.sel && !root.sel.mine && root.sel.mySubmitted)
                            spacing: 10
                            SectionLabel { text: "YOUR ANSWERS" }
                            Text { textFormat: Text.PlainText
                                visible: !!(root.sel && root.sel.mySubmitted && !root.sel.myAnswers)
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: "Sent from an older WhisperBox that didn't keep a copy. Only the creator can read them now."
                                font.pixelSize: 12; color: root.wbTextTert
                            }
                            Repeater {
                                model: (root.sel && root.sel.myAnswers) ? root.sel.questions : []
                                ColumnLayout {
                                    Layout.fillWidth: true
                                    spacing: 2
                                    property var v: {
                                        var a = root.sel.myAnswers.answers || [];
                                        for (var i = 0; i < a.length; i++) if (a[i].questionId === modelData.id) return a[i].value;
                                        return null;
                                    }
                                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        text: modelData.text; font.pixelSize: 12; color: root.wbTextTert }
                                    Text { textFormat: Text.PlainText; Layout.fillWidth: true; wrapMode: Text.WordWrap
                                        property string t: root.answerText(modelData, parent.v)
                                        text: t.length ? t : "(no answer)"
                                        font.pixelSize: 14; color: t.length ? root.wbText : root.wbTextTert }
                                }
                            }
                            Text { textFormat: Text.PlainText
                                visible: !!(root.sel && root.sel.myAnswers)
                                Layout.fillWidth: true; wrapMode: Text.WordWrap
                                text: "Kept only on this device. What went out is sealed - only the creator can open it."
                                font.pixelSize: 11; color: root.wbTextTert
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
                                    model: (qBlock.qt === "radioButtons" || qBlock.qt === "checkbox") ? (qBlock.q.options || []) : (qBlock.qt === "boolean" ? ["Yes", "No"] : [])
                                    Rectangle {
                                        id: opt
                                        Layout.fillWidth: true
                                        implicitHeight: 40
                                        radius: 10
                                        property bool multi: qBlock.qt === "checkbox"
                                        property bool on: multi ? root.toList(root.answers[qBlock.q.id]).indexOf(index) >= 0
                                                                : (qBlock.qt === "boolean" ? root.answers[qBlock.q.id] === (index === 0) : root.answers[qBlock.q.id] === index)
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
                                            onClicked: opt.multi ? root.toggleChoice(qBlock.q.id, index) : root.setAnswer(qBlock.q.id, qBlock.qt === "boolean" ? index === 0 : index)
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

            RowLayout {
                Layout.fillWidth: true
                Text { textFormat: Text.PlainText; Layout.fillWidth: true; text: root.draftId ? "Edit draft" : "New form"; font.pixelSize: 22; font.weight: Font.Bold; color: root.wbText }
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
                WbButton { visible: !!root.draftId; label: "Delete draft"; danger: true; onClicked: root.discardDraft() }
                Item { Layout.fillWidth: true }
                WbButton { label: "Close"; onClicked: root.closeBuilder() }
                WbButton { label: "Save draft"; onClicked: root.saveCurrentDraft(null, function () { root.toast("Draft saved"); }) }
                WbButton { label: root.draftScheduling ? "Don't schedule" : "Schedule..."; onClicked: root.draftScheduling = !root.draftScheduling }
                WbButton { primary: true; label: root.busy("createForm") ? "Publishing..." : "Publish now"; active: !root.busy("createForm"); onClicked: root.doCreate() }
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
