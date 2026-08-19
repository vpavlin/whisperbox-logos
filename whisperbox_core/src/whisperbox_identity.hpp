#pragma once
// whisperbox_core — per-user identity + event signing (C++/OpenSSL secp256k1).
// BYTE-PARITY with packages/contract/src/crypto.mjs:
//   pub       = secp256k1 compressed point (33B) from the 32B scalar
//   address   = "0x" + hex(sha256(pub_compressed_33B))[48..64]   (last 20 bytes; qaku convention)
//   canonicalMessage(e) = "whisperbox-sig-v1|" + type + "|" + wall + "|" + ctr + "|"
//                         + dev + "|" + id + "|" + cjson(payload)
//   digest    = sha256(utf8(canonicalMessage))
//   sig       = secp256k1 ECDSA over digest, compact r||s (64B) hex, LOW-S
// Verifier accepts low-S and high-S alike (OpenSSL does not enforce low-S; the TS
// side normalizes high-S → same acceptance set on both platforms).
#include <string>
#include <vector>
#include <algorithm>
#include <cstdio>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/obj_mac.h>
#include <openssl/bn.h>
#include "whisperbox_crypto.hpp"   // Bytes, toHex, fromHex, sha256, strBytes
#include "whisperbox_types.hpp"    // Event, HLC, json

namespace whisperbox {

inline std::string toLower(std::string s) {
    for (char& c : s) if (c >= 'A' && c <= 'Z') c = char(c - 'A' + 'a');
    return s;
}

struct SignId {
    Bytes priv;            // 32B scalar
    Bytes pub;             // 33B compressed point
    std::string address;   // "0x" + 40 lowercase hex
    std::string pubHex;    // 66 lowercase hex
    bool valid = false;
};

// JSON.stringify(string): quote + escape ", \\, control chars (\uXXXX lowercase);
// bytes >= 0x80 pass through untouched (UTF-8), exactly like JS JSON.stringify.
inline std::string jsonString(const std::string& s) {
    std::string o = "\"";
    for (unsigned char c : s) {
        switch (c) {
            case '"':  o += "\\\""; break;
            case '\\': o += "\\\\"; break;
            case '\b': o += "\\b"; break;
            case '\f': o += "\\f"; break;
            case '\n': o += "\\n"; break;
            case '\r': o += "\\r"; break;
            case '\t': o += "\\t"; break;
            default:
                if (c < 0x20) { char buf[8]; std::snprintf(buf, sizeof buf, "\\u%04x", c); o += buf; }
                else o += (char)c;
        }
    }
    return o + "\"";
}

// Canonical JSON matching crypto.mjs cjson(): sorted object keys, compact, JS number
// formatting. WhisperBox payloads are strings/ints/bools/nested objects/arrays.
inline std::string cjson(const json& v) {
    if (v.is_null()) return "null";
    if (v.is_boolean()) return v.get<bool>() ? "true" : "false";
    if (v.is_string()) return jsonString(v.get<std::string>());
    if (v.is_number_integer()) return std::to_string(v.get<long long>());
    if (v.is_number_unsigned()) return std::to_string(v.get<unsigned long long>());
    if (v.is_number_float()) return json(v).dump(); // fallback; payloads avoid floats
    if (v.is_array()) {
        std::string o = "[";
        for (size_t i = 0; i < v.size(); i++) { if (i) o += ","; o += cjson(v[i]); }
        return o + "]";
    }
    if (v.is_object()) {
        std::vector<std::string> keys;
        for (auto it = v.begin(); it != v.end(); ++it) keys.push_back(it.key());
        std::sort(keys.begin(), keys.end());
        std::string o = "{";
        for (size_t i = 0; i < keys.size(); i++) { if (i) o += ","; o += jsonString(keys[i]) + ":" + cjson(v.at(keys[i])); }
        return o + "}";
    }
    return "null";
}

inline std::string canonicalMessage(const Event& e) {
    const std::string& dev = !e.hlc.dev.empty() ? e.hlc.dev : e.dev;
    return "whisperbox-sig-v1|" + e.type + "|" + std::to_string(e.hlc.wall) + "|"
         + std::to_string(e.hlc.ctr) + "|" + dev + "|" + e.id + "|" + cjson(e.payload);
}

// ── Identity derivation ────────────────────────────────────────────────────────────
inline SignId identityFromPriv(const Bytes& priv) {
    SignId id;
    if (priv.size() != 32) return id;
    try {
        id.pub = pubFromPriv(priv); // throws on invalid scalar (0, >= n, bad point)
    } catch (...) { return id; }
    id.priv = priv;
    id.pubHex = toHex(id.pub);
    Bytes h = sha256(id.pub);
    id.address = "0x" + toHex(h.data(), 32).substr(24, 40);
    id.valid = true;
    return id;
}

inline SignId generateIdentity() {
    Bytes priv(32);
    for (int tries = 0; tries < 8; tries++) {
        RAND_bytes(priv.data(), 32);
        SignId id = identityFromPriv(priv); // rejects the (astronomically rare) invalid scalar
        if (id.valid) return id;
    }
    return SignId{};
}

// ── ECDSA compact r||s (64B), low-S normalized ────────────────────────────────────
inline Bytes ecdsaSignLowS(const Bytes& priv, const Bytes& digest32) {
    Bytes out;
    EC_KEY* key = EC_KEY_new_by_curve_name(NID_secp256k1);
    BN_CTX* ctx = BN_CTX_new();
    BIGNUM* bn = BN_bin2bn(priv.data(), (int)priv.size(), nullptr);
    if (key && bn && EC_KEY_set_private_key(key, bn) == 1) {
        ECDSA_SIG* sig = ECDSA_do_sign(digest32.data(), (int)digest32.size(), key);
        if (sig) {
            const BIGNUM* r; const BIGNUM* s;
            ECDSA_SIG_get0(sig, &r, &s);
            const EC_GROUP* grp = EC_KEY_get0_group(key);
            BIGNUM* order = BN_new(); EC_GROUP_get_order(grp, order, ctx);
            BIGNUM* half = BN_new(); BN_rshift1(half, order);
            BIGNUM* sN = BN_dup(s);
            if (BN_cmp(sN, half) > 0) BN_sub(sN, order, sN); // low-S
            out.assign(64, 0);
            BN_bn2binpad(r, out.data(), 32);
            BN_bn2binpad(sN, out.data() + 32, 32);
            BN_free(sN); BN_free(half); BN_free(order);
            ECDSA_SIG_free(sig);
        }
    }
    BN_free(bn); BN_CTX_free(ctx); EC_KEY_free(key);
    return out;
}

inline bool ecdsaVerify(const Bytes& pub33, const Bytes& digest32, const Bytes& sig64) {
    if (pub33.size() != 33 || sig64.size() != 64) return false;
    bool ok = false;
    EC_KEY* key = EC_KEY_new_by_curve_name(NID_secp256k1);
    BN_CTX* ctx = BN_CTX_new();
    const EC_GROUP* grp = EC_KEY_get0_group(key);
    EC_POINT* pt = EC_POINT_new(grp);
    if (EC_POINT_oct2point(grp, pt, pub33.data(), 33, ctx) == 1 && EC_KEY_set_public_key(key, pt) == 1) {
        ECDSA_SIG* sig = ECDSA_SIG_new();
        BIGNUM* r = BN_bin2bn(sig64.data(), 32, nullptr);
        BIGNUM* s = BN_bin2bn(sig64.data() + 32, 32, nullptr);
        ECDSA_SIG_set0(sig, r, s); // takes ownership of r,s
        ok = ECDSA_do_verify(digest32.data(), (int)digest32.size(), sig, key) == 1;
        ECDSA_SIG_free(sig);
    }
    EC_POINT_free(pt); BN_CTX_free(ctx); EC_KEY_free(key);
    return ok;
}

// Stamp the event's authenticity layer (pub/sig). Does NOT touch dev/hlc.dev —
// those are set by the local Clock (device name), matching crypto.mjs signEvent.
inline void signEvent(const SignId& id, Event& e) {
    Bytes digest = sha256(strBytes(canonicalMessage(e)));
    Bytes sig = ecdsaSignLowS(id.priv, digest);
    e.pub = id.pubHex;
    e.sig = toHex(sig.data(), (int)sig.size());
}

// True iff the event is well-signed by the key whose address it claims.
// Claimed identity: form.publish → payload.creator; other gated events →
// payload.author. (dev/hlc.dev is HLC device metadata, NOT an identity claim.)
// Never throws.
inline bool verifyEvent(const Event& e) {
    if (e.pub.empty() || e.sig.empty() || e.type.empty() || e.id.empty()) return false;
    const std::string claimed = (e.type == "form.publish")
        ? (e.payload.contains("creator") && e.payload["creator"].is_string()
             ? e.payload["creator"].get<std::string>() : "")
        : (e.payload.contains("author") && e.payload["author"].is_string()
             ? e.payload["author"].get<std::string>() : "");
    if (claimed.empty()) return false;
    Bytes pub = fromHex(e.pub);
    if (pub.size() != 33) return false;
    Bytes h = sha256(pub);
    if ("0x" + toHex(h.data(), 32).substr(24, 40) != toLower(claimed)) return false; // claimed address must match key
    Bytes sig = fromHex(e.sig);
    if (sig.size() != 64) return false;
    Bytes digest = sha256(strBytes(canonicalMessage(e)));
    return ecdsaVerify(pub, digest, sig);
}

// JSON-based convenience (the module layer passes events as nlohmann json).
// Never throws.
inline bool verifyEventJson(const json& e) {
    Event ev;
    ev.v = e.value("v", 1);
    ev.id = e.value("id", "");
    ev.type = e.value("type", "");
    if (e.contains("hlc") && e["hlc"].is_object()) {
        ev.hlc.wall = e["hlc"].value("wall", 0LL);
        ev.hlc.ctr = e["hlc"].value("ctr", 0LL);
        ev.hlc.dev = e["hlc"].value("dev", "");
    }
    ev.dev = e.value("dev", "");
    if (e.contains("payload") && e["payload"].is_object()) ev.payload = e["payload"];
    ev.pub = e.value("pub", "");   // null/absent → "" (unsigned)
    ev.sig = e.value("sig", "");
    return verifyEvent(ev);
}

// JSON-based signing (the module layer passes events as nlohmann json):
// adds pub/sig to the envelope in place. Never throws for a valid identity.
inline void signEventJson(json& e, const SignId& id) {
    Event ev;
    ev.v = e.value("v", 1);
    ev.id = e.value("id", "");
    ev.type = e.value("type", "");
    if (e.contains("hlc") && e["hlc"].is_object()) {
        ev.hlc.wall = e["hlc"].value("wall", 0LL);
        ev.hlc.ctr = e["hlc"].value("ctr", 0LL);
        ev.hlc.dev = e["hlc"].value("dev", "");
    }
    ev.dev = e.value("dev", "");
    if (e.contains("payload") && e["payload"].is_object()) ev.payload = e["payload"];
    signEvent(id, ev);
    e["pub"] = ev.pub;
    e["sig"] = ev.sig;
}

} // namespace whisperbox
