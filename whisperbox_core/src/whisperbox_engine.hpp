#pragma once
#include <cctype>
#include <cmath>
#include <regex>
// whisperbox_engine.hpp — pure, deterministic fold from a merged WhisperBox event
// log to app state (computeState) + CREATOR VIEW (creatorView). C++ port of
// packages/engine/src/engine.mjs (the TS reference; golden vectors in
// packages/engine/test/fixtures pin the contract — three-way parity with
// loam-sync's merge semantics where they overlap).
//
// Two layers (privacy ground truth — see events.mjs header):
//   1. LOG FOLD (computeState): syncs opaque events. Responses are sealed blobs;
//      the fold stores them in a global pool, HLC-ordered. It can route/dedup by
//      content hash only — it never sees formId/respondent inside a response.
//   2. CREATOR VIEW (creatorView): given the folded state + an injected open()
//      (ECIES decrypt with the creator's key), assigns blobs to forms, enforces
//      one-response-per-respondent (earliest HLC wins), closed-form drops, and
//      whitelist signature checks. Pure & deterministic per replica.
//
// Determinism rules (must match the TS reference exactly):
//  - Input is the HLC-ordered merged log (mergeWhisperbox). Single pass, in order.
//  - `forms` keys are inserted in HLC publish order; state JSON is emitted with
//    nlohmann::ordered_json so serialization preserves that order on every replica.
//  - All address comparisons are case-insensitive (lowercased).
//  - No randomness, no wall-clock reads, no iteration over unordered structures.
#include <string>
#include <vector>
#include <map>
#include <set>
#include <functional>
#include <algorithm>
#include "whisperbox_types.hpp"   // json alias (nlohmann::json)
#include "whisperbox_crypto.hpp"  // Bytes, sha256, toHex (id helpers)

namespace whisperbox {

using OrderedJson = nlohmann::ordered_json;

inline std::string lc(std::string s) {
    for (char& c : s) if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
    return s;
}

// Event type constants (mirror events.mjs).
inline const std::string FORM_PUBLISH      = "form.publish";
inline const std::string RESPONSE_SUBMIT   = "response.submit";
inline const std::string RESPONSE_CONFIRM  = "response.confirm";
inline const std::string FORM_CLOSE        = "form.close";
inline const std::string FORM_REOPEN       = "form.reopen";   // 0.3.2+: creator re-opens
inline const std::string FORM_UPDATE       = "form.update";   // 0.3.6+: creator edits a published form
inline const std::string TOPIC             = "/whisperbox/1/all/proto";

// ── HLC total order: wall → ctr → dev. Identical on every replica. ───────────────
inline int compareHlc(const json& a, const json& b) {
    long long aw = a.value("wall", 0LL), bw = b.value("wall", 0LL);
    if (aw != bw) return aw < bw ? -1 : 1;
    long long ac = a.value("ctr", 0LL), bc = b.value("ctr", 0LL);
    if (ac != bc) return ac < bc ? -1 : 1;
    std::string ad = a.value("dev", ""), bd = b.value("dev", "");
    if (ad != bd) return ad < bd ? -1 : 1;
    return 0;
}

// Total order: HLC, then event id as a defensive tiebreak (a buggy/adversarial
// peer might emit two identical HLCs — the id tiebreak keeps the merged log a
// function of the event SET alone).
inline int totalOrder(const json& a, const json& b) {
    int c = compareHlc(a.value("hlc", json::object()), b.value("hlc", json::object()));
    if (c != 0) return c;
    std::string aid = a.value("id", ""), bid = b.value("id", "");
    if (aid != bid) return aid < bid ? -1 : 1;
    return 0;
}

// Dedup key (mirror merge.mjs eventKey): signed events by (id, signer) so a forged copy
// can't shadow the genuine event under a deterministic id; unsigned (sealed responses,
// content-addressed) by id.
inline std::string eventKey(const json& e) {
    std::string id = e.value("id", "");
    if (e.contains("pub") && e["pub"].is_string() && !e["pub"].get<std::string>().empty())
        return id + "#" + e["pub"].get<std::string>();
    return id;
}

// ── Merge: union by id with MIN-HLC conflict rule (documented deviation from
// loam-sync's concat-order win — natural ids can legitimately carry different
// payloads, e.g. a resubmission; min-HLC is replica-deterministic). Pure. ────────
inline std::vector<json> mergeWhisperbox(std::vector<std::vector<json>> logs) {
    std::map<std::string, json> byId;   // ordered map: deterministic iteration
    for (const auto& log : logs) {
        for (const auto& e : log) {
            if (!e.contains("id") || !e["id"].is_string() || e["id"].get<std::string>().empty()) continue;
            const std::string id = eventKey(e);
            auto it = byId.find(id);
            if (it == byId.end()) {
                byId.emplace(id, e);
            } else {
                int c = compareHlc(e.value("hlc", json::object()), it->second.value("hlc", json::object()));
                if (c < 0) it->second = e;   // keep the earliest-HLC copy
            }
        }
    }
    std::vector<json> out;
    out.reserve(byId.size());
    for (auto& kv : byId) out.push_back(kv.second);
    // totalOrder is a 3-way compare (-1/0/1); std::sort needs a strict "less".
    std::sort(out.begin(), out.end(), [](const json& a, const json& b) { return totalOrder(a, b) < 0; });
    return out;
}

// Merge one event into an already-merged log in place. Returns true if NEW.
inline bool mergeOne(std::vector<json>& log, const json& e) {
    if (!e.contains("id") || !e["id"].is_string()) return false;
    const std::string key = eventKey(e);
    for (auto x = log.begin(); x != log.end(); ++x) {
        if (eventKey(*x) != key) continue;
        // Same key: an EARLIER-HLC copy replaces the held one (min-HLC rule, arrival-order
        // independent - same as mergeWhisperbox); otherwise it's a duplicate.
        if (compareHlc(e.value("hlc", json::object()), x->value("hlc", json::object())) >= 0) return false;
        log.erase(x);
        break;
    }
    // Walk back from the end past every event ordered AFTER e, then insert —
    // keeps the log HLC-sorted (the fold's single-pass invariant).
    auto it = log.end();
    while (it != log.begin()) {
        auto prev = std::prev(it);
        if (totalOrder(*prev, e) > 0) it = prev; else break;
    }
    log.insert(it, e);
    return true;
}

// ── Fold helpers ─────────────────────────────────────────────────────────────────
struct Dropped { int count = 0; std::map<std::string, int> reasons; };

inline void drop(Dropped& d, const std::string& reason) {
    d.count += 1;
    d.reasons[reason] += 1;
}

inline json droppedToJson(const Dropped& d) {
    OrderedJson r = OrderedJson::object();
    for (const auto& kv : d.reasons) r[kv.first] = kv.second;
    return json({{"count", d.count}, {"reasons", r}});
}

// Local hybrid logical clock (mirror of hlc.mjs Clock). Prime from the log on
// load (primeFrom), call send() to stamp local events, receive() for ingested.
struct Clock {
    std::string dev;
    long long wall = 0, ctr = 0;
    Clock() = default;   // the generated glue default-constructs the impl
    explicit Clock(std::string d) : dev(std::move(d)) {}
    json send(long long nowMs) {
        if (nowMs > wall) { wall = nowMs; ctr = 0; } else { ctr += 1; }
        return json({{"wall", wall}, {"ctr", ctr}, {"dev", dev}});
    }
    void receive(const json& h) {
        long long hw = h.value("wall", 0LL), hc = h.value("ctr", 0LL);
        if (hw > wall) { wall = hw; ctr = hc; }
        else if (hw == wall) { ctr = std::max(ctr, hc); }
    }
    void primeFrom(const std::vector<json>& log) {
        for (const auto& e : log) receive(e.value("hlc", json::object()));
    }
};

// ── computeState: fold a merged event log into app state. Pure. ─────────────────
// opts.identity — address whose creator projections to include ("" = none).
// opts.verify   — authenticity hook for SIGNED gated events; null = permissive
//                 (transition semantics — strict-drop silently hid redelivered
//                 copies of your own submissions).
// The fields a creator may change with form.update - normalized the same way on publish
// and on update (mirror engine.mjs editableFields).
inline void applyEditableFields(OrderedJson& f, const json& p) {
    auto str = [&p](const char* k) { return p.contains(k) && p[k].is_string() ? p[k].get<std::string>() : std::string(); };
    auto flag = [&p](const char* k) { return p.contains(k) && p[k].is_boolean() && p[k].get<bool>(); };
    f["title"] = str("title");
    f["description"] = str("description");
    f["expiresAt"] = p.contains("expiresAt") && p["expiresAt"].is_number() ? p["expiresAt"] : json(nullptr);
    f["questions"] = p.contains("questions") && p["questions"].is_array() ? p["questions"] : json::array();
    f["whitelist"] = p.contains("whitelist") && p["whitelist"].is_object() ? p["whitelist"] : json({{"type", "none"}, {"value", ""}});
    {   // answer cap: a positive integer, else null (mirror Number.isInteger)
        json mr = nullptr;
        if (p.contains("maxResponses") && p["maxResponses"].is_number()) {
            double d = p["maxResponses"].get<double>();
            if (d > 0 && d == (double)(long long)d) mr = (long long)d;
        }
        f["maxResponses"] = mr;
    }
    f["showResponseCount"] = flag("showResponseCount");
    f["thankYou"] = str("thankYou");
    f["shuffleQuestions"] = flag("shuffleQuestions");
    // answer edits: window after the first answer, until the receipt
    const bool ae = flag("allowEdits");
    f["allowEdits"] = ae;
    json win = nullptr;
    if (ae) { win = 15; if (p.contains("editWindowMinutes") && p["editWindowMinutes"].is_number_integer() && p["editWindowMinutes"].get<long long>() > 0) win = p["editWindowMinutes"]; }
    f["editWindowMinutes"] = win;
}

inline OrderedJson computeState(const std::vector<json>& mergedLog,
                                const std::string& identity = "",
                                std::function<bool(const json&)> verify = nullptr,
                                const std::map<std::string, std::string>& prefer = {}) {
    const std::string ident = lc(identity);
    // Contested form ids (published by >1 creator): every contender folds on its own;
    // the device then shows its own copy, else the link-pinned (prefer) creator's, else
    // the first (mirror engine.mjs).
    std::map<std::string, std::map<std::string, OrderedJson>> alts;   // formId -> creator -> view
    std::map<std::string, json> closeHlcBy;                            // "formId|creator" -> hlc
    std::map<std::string, std::vector<std::pair<json, json>>> spansBy; // "formId|creator" -> closed periods (from, to|null)
    std::map<std::string, std::map<std::string, json>> receiptHlcBy;  // "formId|creator" -> confirmationId -> first receipt hlc

    OrderedJson forms = OrderedJson::object();   // insertion order = HLC publish order
    std::vector<std::pair<std::string, json>> formHlc;  // (formId, publish hlc) — feed ordering
    std::map<std::string, json> closeHlc;        // formId → close event hlc
    std::vector<json> responses;                 // opaque pool, HLC order
    std::vector<json> deferred;                  // gated events for not-yet-folded forms
    Dropped dropped;

    std::function<void(const json&)> applyEvent = [&](const json& e) {
        const std::string type = e.value("type", "");
        const json p = e.value("payload", json::object());
        if (type == FORM_PUBLISH) {
            std::string formId = lc(p.value("id", ""));
            OrderedJson f = OrderedJson::object();
            f["id"] = formId;
            f["creator"] = lc(p.value("creator", ""));
            f["publicKey"] = p.contains("publicKey") && p["publicKey"].is_string() ? p["publicKey"].get<std::string>() : std::string();
            f["createdAt"] = p.contains("createdAt") && p["createdAt"].is_number() ? p["createdAt"] : json(0);
            applyEditableFields(f, p);
            f["version"] = 1;          // +1 per form.update
            f["updatedAt"] = nullptr;  // hlc.wall of the latest update
            f["status"] = "open";
            f["confirmations"] = json::array();
            if (forms.contains(formId)) {
                const std::string c = f["creator"].get<std::string>();
                if (c != forms[formId]["creator"].get<std::string>()) {
                    if (!alts[formId].count(c)) alts[formId][c] = f;
                    forms[formId]["contested"] = true;
                }
                return;
            }
            forms[formId] = f;
            formHlc.push_back({formId, e.value("hlc", json::object())});
            // Lenient ordering: replay deferred gated events for this form in HLC order.
            std::vector<json> mine;
            for (int i = (int)deferred.size() - 1; i >= 0; i--) {
                if (lc(deferred[i].value("payload", json::object()).value("formId", "")) == formId) {
                    mine.insert(mine.begin(), deferred[i]);
                    deferred.erase(deferred.begin() + i);
                }
            }
            for (const auto& d : mine) applyEvent(d);
            return;
        }
        if (type == RESPONSE_SUBMIT) {
            // OPAQUE sealed blob. No form routing, no admission at log level —
            // interpretation happens in creatorView after decryption. Never dropped.
            json r = OrderedJson::object();
            r["id"] = e.value("id", "");
            r["hlc"] = e.value("hlc", json::object());
            r["encryptedPayload"] = p.value("encryptedPayload", "");
            responses.push_back(r);
            return;
        }
        if (type == RESPONSE_CONFIRM || type == FORM_CLOSE || type == FORM_REOPEN || type == FORM_UPDATE) {
            if (verify && e.contains("sig") && !e["sig"].is_null() && !e["sig"].get<std::string>().empty()
                && !verify(e)) { drop(dropped, "sig-invalid"); return; }
            std::string formId = lc(p.value("formId", ""));
            if (!forms.contains(formId)) { deferred.push_back(e); return; } // lenient: may lead publish
            const std::string author = lc(p.value("author", ""));
            OrderedJson* tf = &forms[formId];
            bool isFirst = true;
            if (author != (*tf)["creator"].get<std::string>()) {
                auto ai = alts.find(formId);
                if (ai == alts.end() || !ai->second.count(author)) { drop(dropped, "not-creator"); return; }
                tf = &ai->second[author]; isFirst = false;   // a contender's own close/confirm
            }
            OrderedJson& f = *tf;
            if (type == FORM_UPDATE) {   // latest update wins; status / receipts / closes stay
                applyEditableFields(f, p.contains("form") && p["form"].is_object() ? p["form"] : json::object());
                f["version"] = f["version"].get<long long>() + 1;
                f["updatedAt"] = e.contains("hlc") && e["hlc"].contains("wall") ? e["hlc"]["wall"] : json(nullptr);
                return;
            }
            if (type == RESPONSE_CONFIRM) {
                // single receipt, or many in one event ("confirm all")
                std::vector<std::string> ids;
                if (p.contains("confirmationIds") && p["confirmationIds"].is_array()) {
                    for (const auto& c : p["confirmationIds"]) if (c.is_string()) ids.push_back(c.get<std::string>());
                } else if (p.contains("confirmationId") && p["confirmationId"].is_string()) ids.push_back(p["confirmationId"].get<std::string>());
                json nc = f["confirmations"];
                auto& rh = receiptHlcBy[formId + "|" + f["creator"].get<std::string>()];
                for (const auto& cid : ids) {
                    if (cid.empty()) continue;
                    bool has = false; for (const auto& c : nc) if (c.get<std::string>() == cid) { has = true; break; }
                    if (!has) { nc.push_back(cid); rh[cid] = e.value("hlc", json::object()); }
                }
                f["confirmations"] = nc;
                return;
            }
            // Close / re-open: log is HLC-ordered, the last one wins; every closed period is
            // kept so answers sealed during any of them stay dropped (mirror engine.mjs).
            const std::string key = formId + "|" + f["creator"].get<std::string>();
            auto& spans = spansBy[key];
            const bool isOpen = spans.empty() || !spans.back().second.is_null();
            if (type == FORM_CLOSE) {
                if (isOpen) spans.push_back({e.value("hlc", json::object()), json(nullptr)});
                f["status"] = "closed";
                if (isFirst) closeHlc[formId] = spans.back().first;
                closeHlcBy[key] = spans.back().first;
                if (p.contains("expiresAt") && !p["expiresAt"].is_null()) f["expiresAt"] = p["expiresAt"];
            } else { // FORM_REOPEN
                if (!isOpen) spans.back().second = e.value("hlc", json::object());
                f["status"] = "open";
                if (isFirst) closeHlc.erase(formId);
                closeHlcBy.erase(key);
            }
            return;
        }
        drop(dropped, "unknown-type");
    };

    for (const auto& e : mergedLog) applyEvent(e);

    // Per-device choice for contested ids (mirror engine.mjs): own > link-pinned > first.
    for (auto& kv : alts) {
        const std::string& formId = kv.first;
        forms[formId]["contested"] = true;
        for (auto& a : kv.second) a.second["contested"] = true;
        const std::string first = forms[formId]["creator"].get<std::string>();
        std::string want;
        if (!ident.empty() && (first == ident || kv.second.count(ident))) want = ident;
        else {
            auto pi = prefer.find(formId);
            if (pi != prefer.end() && (first == lc(pi->second) || kv.second.count(lc(pi->second)))) want = lc(pi->second);
        }
        if (!want.empty() && want != first) {
            forms[formId] = kv.second[want];
            auto ch = closeHlcBy.find(formId + "|" + want);
            if (ch != closeHlcBy.end()) closeHlc[formId] = ch->second; else closeHlc.erase(formId);
        }
    }

    // ── Assemble state (ordered JSON — byte-parity with the TS reference) ──────
    std::vector<std::pair<std::string, json>> feedSrc = formHlc;
    std::sort(feedSrc.begin(), feedSrc.end(), [](const auto& a, const auto& b) {
        return compareHlc(a.second, b.second) < 0; });
    json feed = json::array();
    for (auto& kv : feedSrc)
        if (forms[kv.first]["status"].get<std::string>() == "open") feed.push_back(kv.first);

    OrderedJson state = OrderedJson::object();
    state["v"] = 1;
    state["forms"] = forms;
    state["feed"] = feed;
    state["responses"] = json(responses);          // vector → array (HLC order)
    OrderedJson chj = OrderedJson::object();
    for (auto& kv : closeHlc) chj[kv.first] = kv.second;
    state["closeHlc"] = chj;
    OrderedJson spj = OrderedJson::object();   // closed periods of the creator shown here
    for (auto it = forms.begin(); it != forms.end(); ++it) {
        auto sp = spansBy.find(it.key() + "|" + it.value()["creator"].get<std::string>());
        if (sp == spansBy.end() || sp->second.empty()) continue;
        json arr = json::array();
        for (auto& x : sp->second) arr.push_back(json({{"from", x.first}, {"to", x.second}}));
        spj[it.key()] = arr;
    }
    state["closedSpans"] = spj;
    OrderedJson rhj = OrderedJson::object();   // first receipt per answer (edit lock), shown creator
    for (auto it = forms.begin(); it != forms.end(); ++it) {
        auto r = receiptHlcBy.find(it.key() + "|" + it.value()["creator"].get<std::string>());
        if (r == receiptHlcBy.end() || r->second.empty()) continue;
        OrderedJson o = OrderedJson::object(); for (auto& kv : r->second) o[kv.first] = kv.second;
        rhj[it.key()] = o;
    }
    state["receiptHlc"] = rhj;
    state["creator"] = nullptr;
    OrderedJson pendEvents = OrderedJson::array();
    for (const auto& e : deferred) {
        OrderedJson o = OrderedJson::object(); o["id"] = e.value("id", ""); o["type"] = e.value("type", "");
        pendEvents.push_back(o);
    }
    OrderedJson pending = OrderedJson::object();
    pending["count"] = (int)deferred.size();
    pending["events"] = pendEvents;
    state["pending"] = pending;
    state["dropped"] = droppedToJson(dropped);

    if (!ident.empty()) {
        std::vector<std::string> mine;
        for (auto it = forms.begin(); it != forms.end(); ++it)
            if (it.value()["creator"].get<std::string>() == ident) mine.push_back(it.key());
        if (!mine.empty()) {
            json arr = json::array(); for (auto& m : mine) arr.push_back(m);
            state["creator"] = json({{"address", ident}, {"forms", arr}});
        }
    }

    return state;
}

// Parsed address allow-list of {type:"addresses", value:"0xa,0xb"} (mirror engine.mjs).
inline std::vector<std::string> whitelistAddresses(const json& wl) {
    std::vector<std::string> out;
    std::string v = wl.is_object() && wl.contains("value") && wl["value"].is_string() ? wl["value"].get<std::string>() : "";
    std::string cur;
    auto flush = [&] { if (!cur.empty()) out.push_back(lc(cur)); cur.clear(); };
    for (char c : v) { if (c == ',' || c == ' ' || c == '\t' || c == '\n' || c == '\r') flush(); else cur.push_back(c); }
    flush();
    return out;
}

// ── creatorView: decrypt + interpret the sealed response pool for ONE creator. ──
// open() — ECIES open hook over a hex blob; returns the decrypted response object
//          {formId, respondent, submittedAt, answers, signature} or null when the
//          blob is not for this creator / malformed. Never throws (guard here too).
// verifyResponse — inner-signature check over the DECRYPTED content (whitelist !=
//          none). Injected so the engine stays crypto-free.
inline OrderedJson creatorView(const OrderedJson& state, const std::string& identity,
                               std::function<json(const std::string&)> open,
                               std::function<bool(const json&)> verifyResponse = nullptr) {
    const std::string ident = lc(identity);
    const auto& forms = state["forms"];

    std::vector<std::string> mine;
    for (auto it = forms.begin(); it != forms.end(); ++it)
        if (it.value()["creator"].get<std::string>() == ident) mine.push_back(it.key());

    OrderedJson view = OrderedJson::object();
    view["address"] = ident;
    json formsArr = json::array(); for (auto& m : mine) formsArr.push_back(m);
    view["forms"] = formsArr;
    OrderedJson respObj = OrderedJson::object(), confObj = OrderedJson::object();
    for (auto& f : mine) { respObj[f] = json::array(); confObj[f] = forms[f]["confirmations"]; }
    view["confirmations"] = confObj;
    // NOTE: view["responses"] is assigned AFTER the loop — nlohmann assignment is
    // by value, so assigning before the loop would snapshot an empty object and
    // silently discard every response pushed into respObj below.
    Dropped dropped;
    view["undecrypted"] = 0;

    struct EditMeta { long long firstWall = 0; std::string cid; long long index = -1; };
    std::map<std::string, std::map<std::string, EditMeta>> seenRespondent; // formId → respondent → first answer

    const auto& pool = state["responses"];   // HLC-ordered (fold invariant)
    for (const auto& blob : pool) {
      // A respondent controls the decrypted JSON: a malformed field (e.g. "respondent": null)
      // must drop that one answer, never throw out of the whole creator view.
      try {
        json dec;
        try { dec = open(blob["encryptedPayload"].get<std::string>()); } catch (...) { dec = json(); }
        if (!dec.is_object()) { view["undecrypted"] = view["undecrypted"].get<int>() + 1; continue; }

        std::string formId = lc(dec.value("formId", ""));
        if (!forms.contains(formId) || forms.at(formId)["creator"].get<std::string>() != ident) continue; // not mine

        const auto& f = forms.at(formId);
        const OrderedJson* spans = (state.contains("closedSpans") && state["closedSpans"].contains(formId)) ? &state["closedSpans"][formId] : nullptr;
        if (spans && !spans->empty()) {
            // sealed while the form was closed - any closed period, even if re-opened since
            bool inClosed = false;
            for (const auto& s : *spans)
                if (compareHlc(blob["hlc"], s["from"]) >= 0 && (s["to"].is_null() || compareHlc(blob["hlc"], s["to"]) < 0)) { inClosed = true; break; }
            if (inClosed) { drop(dropped, "form-closed"); continue; }
        } else if (f["status"].get<std::string>() == "closed") {
            // Closed-form drop: blob's HLC after the close event's HLC. Cross-device
            // HLC comparison is approximate (clock skew) — best-effort, documented.
            bool afterClose = true;
            if (state.contains("closeHlc") && state["closeHlc"].contains(formId))
                afterClose = compareHlc(blob["hlc"], state["closeHlc"][formId]) >= 0;
            else afterClose = true;   // no close hlc recorded → treat as closed
            if (afterClose) { drop(dropped, "form-closed"); continue; }
        }

        // Close-at date (expiresAt, ms): answers stamped after it don't count.
        if (f.contains("expiresAt") && f["expiresAt"].is_number() && blob["hlc"].contains("wall")
            && blob["hlc"]["wall"].get<double>() > f["expiresAt"].get<double>()) { drop(dropped, "expired"); continue; }

        // Whitelist + inner signature (original: enforced only when whitelist != none).
        std::string wlType = f["whitelist"].value("type", "none");
        const bool allowEdits = f.contains("allowEdits") && f["allowEdits"].is_boolean() && f["allowEdits"].get<bool>();
        if ((wlType != "none" || allowEdits) && verifyResponse) {   // edits must be signed too
            OrderedJson pseudo = OrderedJson::object();
            pseudo["v"] = 1;
            pseudo["id"] = blob["id"];
            pseudo["type"] = RESPONSE_SUBMIT;
            pseudo["hlc"] = blob["hlc"];
            pseudo["dev"] = "";
            pseudo["payload"] = dec;
            pseudo["pub"] = dec.contains("pub") ? dec["pub"] : nullptr;
            pseudo["sig"] = dec.value("signature", (json) nullptr);
            if (!verifyResponse(pseudo)) { drop(dropped, "sig-invalid"); continue; }
        }

        std::string respondent = lc(dec.value("respondent", ""));
        if (respondent.empty()) { drop(dropped, "no-respondent"); continue; }
        // Address allow-list (mirror engine.mjs): only listed respondents count.
        if (wlType == "addresses") {
            auto allowed = whitelistAddresses(f["whitelist"]);
            if (std::find(allowed.begin(), allowed.end(), respondent) == allowed.end()) {
                drop(dropped, "not-whitelisted"); continue;
            }
        }
        auto& seen = seenRespondent[formId];
        auto prevIt = seen.find(respondent);
        if (prevIt != seen.end()) {
            // a later response from the same respondent = an EDIT (mirror engine.mjs)
            EditMeta& pm = prevIt->second;
            if (!allowEdits || pm.index < 0) { drop(dropped, "duplicate-respondent"); continue; }
            const long long win = (f["editWindowMinutes"].is_number() ? f["editWindowMinutes"].get<long long>() : 15) * 60000LL;
            if (blob["hlc"].value("wall", 0LL) - pm.firstWall > win) { drop(dropped, "edit-too-late"); continue; }
            if (state.contains("receiptHlc") && state["receiptHlc"].contains(formId) && !pm.cid.empty()
                && state["receiptHlc"][formId].contains(pm.cid) && compareHlc(blob["hlc"], state["receiptHlc"][formId][pm.cid]) >= 0) { drop(dropped, "edit-after-receipt"); continue; }
            auto& e = respObj[formId][(size_t)pm.index];
            e["submittedAt"] = dec.contains("submittedAt") && !dec["submittedAt"].is_null() ? dec["submittedAt"] : json(nullptr);
            e["answers"] = dec.value("answers", json::array());
            e["signature"] = dec.contains("signature") ? dec["signature"] : nullptr;
            e["edits"] = e["edits"].get<int>() + 1;
            continue;
        }
        EditMeta meta; meta.firstWall = blob["hlc"].value("wall", 0LL);
        meta.cid = dec.contains("confirmationId") && dec["confirmationId"].is_string() ? dec["confirmationId"].get<std::string>() : "";
        seen[respondent] = meta;
        // Answer cap: the first maxResponses in HLC order count (same on every replica).
        if (f.contains("maxResponses") && f["maxResponses"].is_number()
            && (long long)respObj[formId].size() >= f["maxResponses"].get<long long>()) { drop(dropped, "over-limit"); continue; }

        OrderedJson r = OrderedJson::object();
        r["respondent"] = respondent;
        r["submittedAt"] = dec.contains("submittedAt") && !dec["submittedAt"].is_null() ? dec["submittedAt"] : nullptr;
        r["answers"] = dec.value("answers", json::array());
        r["signature"] = dec.contains("signature") ? dec["signature"] : nullptr;
        // Respondent-chosen random receipt id (sealed, unlinkable); null pre-0.2.
        r["confirmationId"] = dec.contains("confirmationId") && dec["confirmationId"].is_string() ? dec["confirmationId"] : json(nullptr);
        r["hlc"] = blob["hlc"];
        if (allowEdits) r["edits"] = 0;   // only on editable forms (keeps older vectors stable)
        seen[respondent].index = (long long)respObj[formId].size();
        respObj[formId].push_back(r);
      } catch (const std::exception&) { drop(dropped, "malformed"); }
    }

    view["responses"] = respObj;   // by-value copy — must happen after all pushes
    view["dropped"] = droppedToJson(dropped);
    return view;
}

// ── Answer validation (mirror contract/src/answers.mjs; fixture answer-validation.json) ──
inline bool answerIsOther(const json& v) { return v.is_object() && v.contains("other"); }
inline bool emptyAnswerValue(const json& v) {
    if (v.is_null()) return true;
    if (v.is_string()) { const std::string& s = v.get_ref<const std::string&>(); return s.find_first_not_of(" \t\r\n") == std::string::npos; }
    if (v.is_array()) return v.empty();
    if (answerIsOther(v)) { const json& o = v["other"]; if (!o.is_string()) return o.is_null();
        const std::string& s = o.get_ref<const std::string&>(); return s.find_first_not_of(" \t\r\n") == std::string::npos; }
    return false;
}
inline bool answerIsInt(const json& v) {
    if (v.is_number_integer()) return true;
    if (v.is_number_float()) { double d = v.get<double>(); return std::isfinite(d) && d == std::floor(d); }
    return false;
}
inline bool validDateStr(const std::string& s) {
    if (s.size() != 10 || s[4] != '-' || s[7] != '-') return false;
    for (int i : {0, 1, 2, 3, 5, 6, 8, 9}) if (!std::isdigit((unsigned char)s[i])) return false;
    int y = std::stoi(s.substr(0, 4)), mo = std::stoi(s.substr(5, 2)), d = std::stoi(s.substr(8, 2));
    if (mo < 1 || mo > 12 || d < 1) return false;
    static const int dm[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    int days = dm[mo - 1]; if (mo == 2 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)) days = 29;
    return d <= days;
}
// "" when ok, else a short reason. Empty answers are only checked for `required`.
inline std::string validateAnswer(const json& q, const json& v) {
    const std::string t = q.value("type", std::string("text"));
    if (t == "section") return "";
    if (emptyAnswerValue(v)) return q.value("required", false) ? "required" : "";
    const long long n = q.contains("options") && q["options"].is_array() ? (long long)q["options"].size() : 0;
    const bool allowOther = q.value("allowOther", false);
    auto otherOk = [&](const json& x) { return allowOther && answerIsOther(x) && x["other"].is_string() && !emptyAnswerValue(x); };
    auto inRange = [&](const json& x) { if (!answerIsInt(x)) return false; double d = x.get<double>(); return d >= 0 && d < (double)n; };
    auto numOr = [&](const char* k, double d) { return q.contains(k) && q[k].is_number() ? q[k].get<double>() : d; };
    auto fmtNum = [](double d) { std::string s = std::to_string(d); if (d == std::floor(d)) s = std::to_string((long long)d); else { s.erase(s.find_last_not_of('0') + 1); } return s; };
    if (t == "text" || t == "textarea") return v.is_string() ? "" : "must be text";
    if (t == "email") { if (!v.is_string()) return "not an email address";
        static const std::regex re("^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$");
        std::string s = v.get<std::string>(); s.erase(0, s.find_first_not_of(" \t")); s.erase(s.find_last_not_of(" \t") + 1);
        return std::regex_match(s, re) ? "" : "not an email address"; }
    if (t == "url") { if (!v.is_string()) return "not a link (https://...)";
        static const std::regex re("^https?://\\S+\\.\\S+$", std::regex::icase);
        std::string s = v.get<std::string>(); s.erase(0, s.find_first_not_of(" \t")); s.erase(s.find_last_not_of(" \t") + 1);
        return std::regex_match(s, re) ? "" : "not a link (https://...)"; }
    if (t == "radioButtons" || t == "dropdown") return inRange(v) || otherOk(v) ? "" : "not one of the options";
    if (t == "checkbox") {
        if (!v.is_array()) return "not a list of options";
        std::set<long long> seen; int others = 0;
        for (const auto& x : v) {
            if (otherOk(x)) { others++; continue; }
            if (!inRange(x) || seen.count((long long)x.get<double>())) return "not one of the options";
            seen.insert((long long)x.get<double>());
        }
        return others > 1 ? "only one 'other' answer" : "";
    }
    if (t == "boolean") return v.is_boolean() ? "" : "must be yes or no";
    if (t == "scale") { double lo = numOr("min", 1), hi = numOr("max", 5);
        return answerIsInt(v) && v.get<double>() >= lo && v.get<double>() <= hi ? "" : "must be " + fmtNum(lo) + "-" + fmtNum(hi); }
    if (t == "number") {
        if (!v.is_number() || !std::isfinite(v.get<double>())) return "must be a number";
        if (q.contains("min") && q["min"].is_number() && v.get<double>() < q["min"].get<double>()) return "at least " + fmtNum(q["min"].get<double>());
        if (q.contains("max") && q["max"].is_number() && v.get<double>() > q["max"].get<double>()) return "at most " + fmtNum(q["max"].get<double>());
        return "";
    }
    if (t == "date") return v.is_string() && validDateStr(v.get<std::string>()) ? "" : "not a date (YYYY-MM-DD)";
    if (t == "time") { static const std::regex re("^([01][0-9]|2[0-3]):[0-5][0-9]$");
        return v.is_string() && std::regex_match(v.get<std::string>(), re) ? "" : "not a time (HH:MM)"; }
    return v.is_string() ? "" : "must be text";   // unknown type: forward-compatible
}

// ── Deterministic id helpers (mirror events.mjs) ────────────────────────────────
inline std::string formPublishId(const std::string& formId) { return "form:" + formId; }
inline std::string responseSubmitId(const std::string& encryptedPayloadHex) {
    Bytes s(encryptedPayloadHex.begin(), encryptedPayloadHex.end());
    return "resp:" + toHex(sha256(s));
}
inline std::string responseConfirmId(const std::string& formId, const std::string& confirmationId) {
    return "confirm:" + lc(formId) + ":" + confirmationId;
}
inline std::string formCloseId(const std::string& formId, const std::string& nonce = "") {
    return nonce.empty() ? "close:" + lc(formId) : "close:" + lc(formId) + ":" + nonce; }
inline std::string formReopenId(const std::string& formId, const std::string& nonce) { return "reopen:" + lc(formId) + ":" + nonce; }
inline std::string formUpdateId(const std::string& formId, const std::string& nonce) { return "update:" + lc(formId) + ":" + nonce; }
inline std::string responseConfirmBatchId(const std::string& formId, std::vector<std::string> ids) {
    std::sort(ids.begin(), ids.end());
    std::string j; for (size_t i = 0; i < ids.size(); i++) { if (i) j += ","; j += ids[i]; }
    return "confirm:" + lc(formId) + ":b:" + toHex(sha256(Bytes(j.begin(), j.end()))).substr(0, 16);
}

} // namespace whisperbox
