// WbAnswers.js - the answer rules and display helpers, shared by the studio (Main.qml) and the
// respond component (FormRespond.qml) of both modules. Pure functions: no view state, no core calls.
// The rules mirror contract/src/answers.mjs; the core enforces them too.
.pragma library

function isList(v) { return v !== null && v !== undefined && typeof v === "object" && typeof v.length === "number"; }
function toList(v) { return isList(v) ? Array.prototype.slice.call(v) : []; }
function plural(n, one, many) { return n + " " + (n === 1 ? one : many); }
function shortAddr(a) { if (!a) return "-"; return a.length > 14 ? a.substr(0, 6) + "..." + a.substr(-4) : a; }
function fmtTime(ms) { if (!ms) return ""; return Qt.formatDateTime(new Date(Number(ms)), "d MMM yyyy, hh:mm"); }
function normType(t) {
    var s = String(t);
    var known = ["text", "textarea", "radioButtons", "checkbox", "boolean", "dropdown", "scale", "number", "date", "time", "email", "url", "section"];
    return known.indexOf(s) >= 0 ? s : "text";
}
function answerText(q, v) {
    if (v === null || v === undefined || v === "") return "";
    var opts = (q && q.options) ? q.options : [];
    var one = function (x) {
        if (typeof x === "boolean") return x ? "Yes" : "No";
        if (x !== null && typeof x === "object" && x.other !== undefined) return "Other: " + x.other;
        return (typeof x === "number" && opts[x] !== undefined) ? String(opts[x]) : String(x);
    };
    if (isList(v)) { var parts = []; for (var i = 0; i < v.length; i++) parts.push(one(v[i])); return parts.join(", "); }
    return one(v);
}
function isOtherVal(v) { return v !== null && v !== undefined && typeof v === "object" && !isList(v) && v.other !== undefined; }
function emptyVal(v) {
    if (v === null || v === undefined) return true;
    if (typeof v === "string") return v.trim() === "";
    if (isList(v)) return v.length === 0;
    if (isOtherVal(v)) return String(v.other || "").trim() === "";
    return false;
}
function validateVal(q, v) {
    var t = normType(q.type);
    if (t === "section") return "";
    if (emptyVal(v)) return q.required ? "required" : "";
    var n = (q.options || []).length, isInt = function (x) { return typeof x === "number" && Math.floor(x) === x; };
    var otherOk = function (x) { return !!q.allowOther && isOtherVal(x) && String(x.other).trim() !== ""; };
    if (t === "text" || t === "textarea") return typeof v === "string" ? "" : "must be text";
    if (t === "email") return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(String(v).trim()) ? "" : "not an email address";
    if (t === "url") return /^https?:\/\/\S+\.\S+$/i.test(String(v).trim()) ? "" : "not a link (https://...)";
    if (t === "radioButtons" || t === "dropdown") return (isInt(v) && v >= 0 && v < n) || otherOk(v) ? "" : "pick one of the options";
    if (t === "checkbox") { var l = toList(v), others = 0; for (var i = 0; i < l.length; i++) { if (otherOk(l[i])) others++; else if (!(isInt(l[i]) && l[i] >= 0 && l[i] < n)) return "pick from the options"; } return others > 1 ? "only one 'other'" : ""; }
    if (t === "boolean") return typeof v === "boolean" ? "" : "pick yes or no";
    if (t === "scale") { var lo = typeof q.min === "number" ? q.min : 1, hi = typeof q.max === "number" ? q.max : 5; return isInt(v) && v >= lo && v <= hi ? "" : "pick " + lo + "-" + hi; }
    if (t === "number") { if (typeof v !== "number" || !isFinite(v)) return "must be a number"; if (typeof q.min === "number" && v < q.min) return "at least " + q.min; if (typeof q.max === "number" && v > q.max) return "at most " + q.max; return ""; }
    if (t === "date") { var m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(v)); if (!m) return "use YYYY-MM-DD"; var d = new Date(+m[1], +m[2] - 1, +m[3]); return d.getMonth() === +m[2] - 1 && d.getDate() === +m[3] ? "" : "not a real date"; }
    if (t === "time") return /^([01]\d|2[0-3]):[0-5]\d$/.test(String(v)) ? "" : "use HH:MM (24 h)";
    return "";
}
function seededOrder(n, seedStr) {
    var h = 2166136261; for (var i = 0; i < seedStr.length; i++) { h ^= seedStr.charCodeAt(i); h = (h * 16777619) >>> 0; }
    var idx = []; for (var k = 0; k < n; k++) idx.push(k);
    for (var j = n - 1; j > 0; j--) { h = (h * 1103515245 + 12345) >>> 0; var r = h % (j + 1); var t = idx[j]; idx[j] = idx[r]; idx[r] = t; }
    return idx;
}
