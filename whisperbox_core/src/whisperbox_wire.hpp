#pragma once
// whisperbox_wire.hpp — on-topic envelope encode/decode + base64 helpers.
//
// Wire model (single shared topic /whisperbox/1/all/proto, see TOPIC in
// whisperbox_engine.hpp): messages are PLAIN JSON envelopes over the delivery
// channel — there is NO transport-level AEAD. Privacy comes from the ECIES-
// sealed response payloads inside response.submit events; form events are public
// by design (public feed). Envelopes:
//   {v:1, type:"EVENT",     event:{...full event envelope...}}
//   {v:1, type:"SYNC_REQ",  from:<deviceId>[, rbsr:true]}  // joiner asks for state
//   {v:2, t:"fp"|"ids"|"need", from, ...}         // loam-sync RBSR catch-up (ids only)
// A SYNC_REQ flagged rbsr comes from a peer that also runs RBSR; RBSR peers ignore it (the
// fp/ids/need exchange already serves the exact delta) while 0.1.x peers, which only know
// SYNC_REQ, answer it with their whole log - so mixed-version topics still converge.
// The channel payload is the base64 TEXT of the envelope (delivery_module
// base64-encodes once more on the wire — peers may need one or two peels; the
// ingest path tries both, same as qaku).
#include <string>
#include "whisperbox_types.hpp"

namespace whisperbox {

static const char kB64T[] =
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

inline std::string b64encode(const Bytes& in) {
    std::string o; int val = 0, bits = -6;
    for (uint8_t c : in) { val = (val << 8) + c; bits += 8;
        while (bits >= 0) { o += kB64T[(val >> bits) & 0x3F]; bits -= 6; } }
    if (bits > -6) o += kB64T[((val << 8) >> (bits + 8)) & 0x3F];
    while (o.size() % 4) o += '=';
    return o;
}
inline std::string b64encode(const std::string& in) {
    return b64encode(Bytes(in.begin(), in.end()));
}
inline std::string b64decode(const std::string& in) {
    std::vector<int> T(256, -1);
    for (int i = 0; i < 64; i++) T[(unsigned char)kB64T[i]] = i;
    T['-'] = 62; T['_'] = 63;   // the URL-safe alphabet too: delivery 0.3 emits it
    std::string o; int val = 0, bits = -8;
    for (unsigned char c : in) {
        if (c == '=') break;
        if (T[c] == -1) continue;      // tolerate stray whitespace/line breaks
        val = (val << 6) + T[c]; bits += 6;
        if (bits >= 0) { o.push_back(char((val >> bits) & 0xFF)); bits -= 8; }
    }
    return o;
}

// Envelope constructors.
inline json envEvent(const json& event) {
    OrderedJson o = OrderedJson::object();
    o["v"] = 1; o["type"] = "EVENT"; o["event"] = event;
    return o;
}
inline json envSyncReq(const std::string& from, bool rbsr = true) {
    OrderedJson o = OrderedJson::object();
    o["v"] = 1; o["type"] = "SYNC_REQ"; o["from"] = from;
    if (rbsr) o["rbsr"] = true;
    return o;
}

// Parse an envelope from raw text. Returns a json with .type set, or null on
// any failure. Never throws.
inline json parseEnvelope(const std::string& text) {
    try {
        json o = json::parse(text);
        if (!o.is_object()) return json();
        // loam-sync RBSR control frame: no "type", {v:2, t:fp|ids|need}.
        if (o.value("v", 0) == 2 && o.contains("t") && o["t"].is_string()) {
            const std::string t = o["t"].get<std::string>();
            if (t == "fp" || t == "ids" || t == "need") { o["type"] = "RBSR"; return o; }
            return json();
        }
        if (!o.contains("type") || !o["type"].is_string()) return json();
        const std::string t = o["type"].get<std::string>();
        if (t == "EVENT" && o.contains("event") && o["event"].is_object()) return o;
        if (t == "SYNC_REQ") return o;
        return json();
    } catch (...) { return json(); }
}

// Event JSON → wire-safe string (ordered dump). Events are stored as plain
// nlohmann::json; the canonical key order of an event does not affect merge or
// fold (the engine reads fields, never bytes), so a plain dump is fine here.
inline std::string eventToJsonText(const json& e) { return e.dump(); }

} // namespace whisperbox
