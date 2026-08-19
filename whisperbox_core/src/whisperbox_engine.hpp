#pragma once
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

// ── Merge: union by id with MIN-HLC conflict rule (documented deviation from
// loam-sync's concat-order win — natural ids can legitimately carry different
// payloads, e.g. a resubmission; min-HLC is replica-deterministic). Pure. ────────
inline std::vector<json> mergeWhisperbox(std::vector<std::vector<json>> logs) {
    std::map<std::string, json> byId;   // ordered map: deterministic iteration
    for (const auto& log : logs) {
        for (const auto& e : log) {
            if (!e.contains("id") || !e["id"].is_string() || e["id"].get<std::string>().empty()) continue;
            const std::string id = e["id"].get<std::string>();
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
    std::sort(out.begin(), out.end(), totalOrder);
    return out;
}

// Merge one event into an already-merged log in place. Returns true if NEW.
inline bool mergeOne(std::vector<json>& log, const json& e) {
    if (!e.contains("id") || !e["id"].is_string()) return false;
    const std::string id = e["id"].get<std::string>();
    for (const auto& x : log) if (x.value("id", "") == id) return false; // dedup by id
    auto it = log.end();
    while (it != log.begin()) {
        auto prev = std::prev(it);
        if (totalOrder(*prev, e) < 0) it = prev; else break;
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
inline OrderedJson computeState(const std::vector<json>& mergedLog,
                                const std::string& identity = "",
                                std::function<bool(const json&)> verify = nullptr) {
    const std::string ident = lc(identity);

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
            if (forms.contains(formId)) return;   // same id ⇒ already folded (defensive)
            OrderedJson f = OrderedJson::object();
            f["id"] = formId;
            f["title"] = p.value("title", "");
            f["description"] = p.value("description", "");
            f["creator"] = lc(p.value("creator", ""));
            f["publicKey"] = p.value("publicKey", "");
            f["createdAt"] = p.value("createdAt", 0LL);
            f["expiresAt"] = p.contains("expiresAt") && !p["expiresAt"].is_null() ? p["expiresAt"] : nullptr;
            f["questions"] = p.value("questions", json::array());
            f["whitelist"] = p.value("whitelist", json({{"type", "none"}, {"value", ""}}));
            f["status"] = "open";
            f["confirmations"] = json::array();
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
        if (type == RESPONSE_CONFIRM || type == FORM_CLOSE) {
            if (verify && e.contains("sig") && !e["sig"].is_null() && !e["sig"].get<std::string>().empty()
                && !verify(e)) { drop(dropped, "sig-invalid"); return; }
            std::string formId = lc(p.value("formId", ""));
            if (!forms.contains(formId)) { deferred.push_back(e); return; } // lenient: may lead publish
            const OrderedJson& f = forms[formId];
            if (lc(p.value("author", "")) != f["creator"].get<std::string>()) { drop(dropped, "not-creator"); return; }
            if (type == RESPONSE_CONFIRM) {
                std::string cid = p.value("confirmationId", "");
                const json confs = f["confirmations"];
                bool has = false; for (const auto& c : confs) if (c.get<std::string>() == cid) { has = true; break; }
                if (!has) { json nc = confs; nc.push_back(cid); forms[formId]["confirmations"] = nc; }
            } else { // FORM_CLOSE — sticky, idempotent
                forms[formId]["status"] = "closed";
                closeHlc[formId] = e.value("hlc", json::object());
                if (p.contains("expiresAt") && !p["expiresAt"].is_null()) forms[formId]["expiresAt"] = p["expiresAt"];
            }
            return;
        }
        drop(dropped, "unknown-type");
    };

    for (const auto& e : mergedLog) applyEvent(e);

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

    std::map<std::string, std::set<std::string>> seenRespondent; // formId → respondents (earliest HLC wins)

    const auto& pool = state["responses"];   // HLC-ordered (fold invariant)
    for (const auto& blob : pool) {
        json dec;
        try { dec = open(blob["encryptedPayload"].get<std::string>()); } catch (...) { dec = json(); }
        if (!dec.is_object()) { view["undecrypted"] = view["undecrypted"].get<int>() + 1; continue; }

        std::string formId = lc(dec.value("formId", ""));
        if (!forms.contains(formId) || forms.at(formId)["creator"].get<std::string>() != ident) continue; // not mine

        const auto& f = forms.at(formId);
        if (f["status"].get<std::string>() == "closed") {
            // Closed-form drop: blob's HLC after the close event's HLC. Cross-device
            // HLC comparison is approximate (clock skew) — best-effort, documented.
            bool afterClose = true;
            if (state.contains("closeHlc") && state["closeHlc"].contains(formId))
                afterClose = compareHlc(blob["hlc"], state["closeHlc"][formId]) >= 0;
            else afterClose = true;   // no close hlc recorded → treat as closed
            if (afterClose) { drop(dropped, "form-closed"); continue; }
        }

        // Whitelist + inner signature (original: enforced only when whitelist != none).
        std::string wlType = f["whitelist"].value("type", "none");
        if (wlType != "none" && verifyResponse) {
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
        auto& seen = seenRespondent[formId];
        if (seen.count(respondent)) { drop(dropped, "duplicate-respondent"); continue; }
        seen.insert(respondent);

        OrderedJson r = OrderedJson::object();
        r["respondent"] = respondent;
        r["submittedAt"] = dec.contains("submittedAt") && !dec["submittedAt"].is_null() ? dec["submittedAt"] : nullptr;
        r["answers"] = dec.value("answers", json::array());
        r["signature"] = dec.contains("signature") ? dec["signature"] : nullptr;
        r["hlc"] = blob["hlc"];
        respObj[formId].push_back(r);
    }

    view["responses"] = respObj;   // by-value copy — must happen after all pushes
    view["dropped"] = droppedToJson(dropped);
    return view;
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
inline std::string formCloseId(const std::string& formId) { return "close:" + lc(formId); }

} // namespace whisperbox
