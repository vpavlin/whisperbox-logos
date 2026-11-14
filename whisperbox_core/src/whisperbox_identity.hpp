#pragma once
#include <cmath>
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
#include <openssl/rand.h>
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

// A number as JavaScript prints it (Number.prototype.toString / JSON.stringify): "1e-7", not
// nlohmann's "1e-07"; "100000000000000000000", not "1e+20"; "-0" is "0". Signed texts are built
// with JSON.stringify on the phones, so a phone answer holding such a number failed to verify on
// the desktop (open-review 2026-11-02, FR-12).
inline std::string esNumber(double d) {
    if (!std::isfinite(d)) return "null";
    if (d == 0) return "0";
    // the shortest round-trip digits (nlohmann prints them), then the ES layout
    std::string r = json(d).dump();
    std::string sign;
    if (r[0] == '-') { sign = "-"; r = r.substr(1); }
    int exp10 = 0;
    auto e = r.find_first_of("eE");
    if (e != std::string::npos) { exp10 = std::stoi(r.substr(e + 1)); r = r.substr(0, e); }
    std::string digits; int pointPos = -1;
    for (char c : r) { if (c == '.') pointPos = (int)digits.size(); else digits.push_back(c); }
    if (pointPos < 0) pointPos = (int)digits.size();
    // value = 0.digits * 10^n
    int n = pointPos + exp10;
    size_t lead = digits.find_first_not_of('0');
    if (lead == std::string::npos) return "0";
    n -= (int)lead; digits = digits.substr(lead);
    while (digits.size() > 1 && digits.back() == '0') digits.pop_back();
    const int k = (int)digits.size();
    std::string out;
    if (k <= n && n <= 21) out = digits + std::string(n - k, '0');
    else if (0 < n && n <= 21) out = digits.substr(0, n) + "." + digits.substr(n);
    else if (-6 < n && n <= 0) out = "0." + std::string(-n, '0') + digits;
    else {
        const int ex = n - 1;
        out = digits.substr(0, 1) + (k > 1 ? "." + digits.substr(1) : std::string()) + "e" + (ex >= 0 ? "+" : "-") + std::to_string(std::abs(ex));
    }
    return sign + out;
}
inline std::string esInteger(long long v) {
    if (v > 9007199254740991LL || v < -9007199254740991LL) return esNumber((double)v);   // past 2^53 JS has a double
    return std::to_string(v);
}
// JSON.stringify of a parsed value, keys in the order the value holds them.
template <class J>
inline std::string esJson(const J& v, int depth = 0) {
    if (depth > 64) throw std::runtime_error("esJson: nested too deep");
    if (v.is_null()) return "null";
    if (v.is_boolean()) return v.template get<bool>() ? "true" : "false";
    if (v.is_string()) return jsonString(v.template get<std::string>());
    if (v.is_number_unsigned()) { auto u = v.template get<unsigned long long>(); return u > 9007199254740991ULL ? esNumber((double)u) : std::to_string(u); }
    if (v.is_number_integer()) return esInteger(v.template get<long long>());
    if (v.is_number_float()) return esNumber(v.template get<double>());
    if (v.is_array()) {
        std::string o = "[";
        for (size_t i = 0; i < v.size(); i++) { if (i) o += ","; o += esJson(v[i], depth + 1); }
        return o + "]";
    }
    if (v.is_object()) {
        std::string o = "{"; bool first = true;
        for (auto it = v.begin(); it != v.end(); ++it) { if (!first) o += ","; first = false; o += jsonString(it.key()) + ":" + esJson(it.value(), depth + 1); }
        return o + "}";
    }
    return "null";
}

// Canonical JSON matching crypto.mjs cjson(): sorted object keys, compact, JS number
// formatting. WhisperBox payloads are strings/ints/bools/nested objects/arrays.
inline std::string cjson(const json& v, int depth = 0) {
    if (depth > 64) throw std::runtime_error("cjson: nested too deep");   // FR-1: never recurse unbounded
    if (v.is_null()) return "null";
    if (v.is_boolean()) return v.get<bool>() ? "true" : "false";
    if (v.is_string()) return jsonString(v.get<std::string>());
    if (v.is_number_unsigned()) { auto u = v.get<unsigned long long>(); return u > 9007199254740991ULL ? esNumber((double)u) : std::to_string(u); }
    if (v.is_number_integer()) return esInteger(v.get<long long>());
    if (v.is_number_float()) return esNumber(v.get<double>());   // as JSON.stringify (FR-12)
    if (v.is_array()) {
        std::string o = "[";
        for (size_t i = 0; i < v.size(); i++) { if (i) o += ","; o += cjson(v[i], depth + 1); }
        return o + "]";
    }
    if (v.is_object()) {
        std::vector<std::string> keys;
        for (auto it = v.begin(); it != v.end(); ++it) keys.push_back(it.key());
        std::sort(keys.begin(), keys.end());
        std::string o = "{";
        for (size_t i = 0; i < keys.size(); i++) { if (i) o += ","; o += jsonString(keys[i]) + ":" + cjson(v.at(keys[i]), depth + 1); }
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
        if (RAND_bytes(priv.data(), 32) != 1) throw std::runtime_error("the random number generator failed");   // FR-14
        SignId id = identityFromPriv(priv); // rejects the (astronomically rare) invalid scalar
        if (id.valid) return id;
    }
    return SignId{};
}

// ── Per-form encryption keys ─────────────────────────────────────────────────────
// Every form gets its OWN sealing key (form.publish payload.publicKey), never the creator's
// identity key. A leaked form key opens one form's answers - not the identity (which signs)
// and not any other form - so one form's key can be handed to a validator hub.
//   soft (identity key on the device):
//     formPriv = first valid scalar of HKDF-SHA256(ikm=identityPriv, salt="whisperbox-formkey-v1",
//                info=utf8(formId) [|| "#" || i for retry i>=1], L=32)
//   keycard: exported from the EIP-1581 subtree, m/43'/60'/1581'/22338'/formKeyIndex(formId)'
//     formKeyIndex = u32be(sha256("whisperbox-formkey-v1|" || formId)[0..4]) & 0x7fffffff
// Respondents are unaffected: they always sealed to the form's publicKey. Legacy forms
// (publicKey == identity pub) keep opening with the identity key.
// Anonymous forms (mirror crypto-portable.mjs deriveAnonIdentity).
inline SignId deriveAnonIdentity(const SignId& identity, const std::string& formId) {
    const std::string fid = toLower(formId);
    for (int i = 0; i < 8; i++) {
        std::string info = i ? fid + "#" + std::to_string(i) : fid;
        SignId k = identityFromPriv(hkdfSha256(identity.priv, strBytes("whisperbox-anon-v1"), strBytes(info), 32));
        if (k.valid) return k;
    }
    return SignId{};
}
// One-off key an answer carries so the creator can reply privately (re-derivable).
inline SignId deriveReplyKey(const SignId& identity, const std::string& formId, const std::string& confirmationId) {
    const std::string base = toLower(formId) + "|" + confirmationId;
    for (int i = 0; i < 8; i++) {
        std::string info = i ? base + "#" + std::to_string(i) : base;
        SignId k = identityFromPriv(hkdfSha256(identity.priv, strBytes("whisperbox-reply-v1"), strBytes(info), 32));
        if (k.valid) return k;
    }
    return SignId{};
}
// Public "dev" tag on a response event, per form (answers can't be linked by device).
inline std::string responseDevTag(const std::string& deviceId, const std::string& formId) {
    std::string s = deviceId + "|" + toLower(formId);
    return "wb-" + toHex(sha256(Bytes(s.begin(), s.end()))).substr(0, 12);
}
inline SignId deriveFormKey(const SignId& identity, const std::string& formId) {
    const std::string fid = toLower(formId);
    for (int i = 0; i < 8; i++) {
        std::string info = i ? fid + "#" + std::to_string(i) : fid;
        SignId k = identityFromPriv(hkdfSha256(identity.priv, strBytes("whisperbox-formkey-v1"), strBytes(info), 32));
        if (k.valid) return k;
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
// Never throws: wrongly-typed fields (a remote peer's choice) mean "not verified".
inline bool verifyEventJson(const json& e) try {
    if (!e.is_object()) return false;
    for (const char* k : {"id", "type", "dev", "pub", "sig"}) if (e.contains(k) && !e[k].is_null() && !e[k].is_string()) return false;
    if (e.contains("v") && !e["v"].is_number_integer()) return false;
    if (e.contains("hlc") && !e["hlc"].is_object()) return false;
    if (e.contains("hlc") && ((e["hlc"].contains("wall") && !e["hlc"]["wall"].is_number_integer()) || (e["hlc"].contains("ctr") && !e["hlc"]["ctr"].is_number_integer())
                              || (e["hlc"].contains("dev") && !e["hlc"]["dev"].is_string()))) return false;
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
    ev.pub = e.contains("pub") && e["pub"].is_string() ? e["pub"].get<std::string>() : "";   // null/absent → "" (unsigned)
    ev.sig = e.contains("sig") && e["sig"].is_string() ? e["sig"].get<std::string>() : "";
    return verifyEvent(ev);
} catch (...) { return false; }

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

// ── Receipts v3 (ADR 0027; mirror crypto-portable.mjs) ───────────────────────────────
// S = ecdhX(replyPriv, formPub) = ecdhX(formPriv, replyPub); tag = hex(sha256("wb-receipt-v3|"||S));
// proof = hex(nonce12 || ChaCha20-Poly1305(HKDF(S,"wb-receipt-v3-key"), nonce, pt, aad = tag)),
// pt = {"at":<ms>,"pub":"<hex>","sig":"<hex>"}, sig over sha256("wb-receipt-v3-sig|formId|cid|at").
inline constexpr size_t kReceiptProofBytes = 260;
inline Bytes receiptSecret(const Bytes& priv32, const Bytes& pub33) { return ecdhX(priv32, pub33); }
inline std::string tagWith(const char* prefix, const Bytes& S) {
    Bytes b = strBytes(prefix); b.insert(b.end(), S.begin(), S.end());
    return toHex(sha256(b));
}
inline std::string receiptTagOf(const Bytes& S) { return tagWith("wb-receipt-v3|", S); }
inline std::string replyTagOf(const Bytes& S) { return tagWith("wb-reply-v3|", S); }
inline Bytes receiptSigDigest(const std::string& formId, const std::string& cid, long long at) {
    return sha256(strBytes("wb-receipt-v3-sig|" + toLower(formId) + "|" + cid + "|" + std::to_string(at)));
}
inline std::string sealReceiptProof(const Bytes& S, const SignId& signer, const std::string& formId, const std::string& cid, long long at) {
    const Bytes sig = ecdsaSignLowS(signer.priv, receiptSigDigest(formId, cid, at));
    const std::string pt = "{\"at\":" + std::to_string(at) + ",\"pub\":\"" + signer.pubHex + "\",\"sig\":\"" + toHex(sig) + "\"}";
    Bytes nonce(12);
    if (RAND_bytes(nonce.data(), 12) != 1) throw std::runtime_error("the random number generator failed");
    const Bytes key = hkdfSha256(S, strBytes("wb-receipt-v3-key"), Bytes(), 32);
    const Bytes ct = aeadSeal(key, nonce, strBytes(pt), strBytes(receiptTagOf(S)));
    Bytes out = nonce; out.insert(out.end(), ct.begin(), ct.end());
    return toHex(out);
}
struct ReceiptProof { bool ok = false; long long at = 0; std::string by; };
inline ReceiptProof openReceiptProof(const Bytes& S, const std::string& formId, const std::string& cid, const std::string& proofHex) try {
    ReceiptProof r;
    const Bytes b = fromHex(proofHex);
    if (b.size() < 12 + 16 + 2 || b.size() > 1024) return r;
    const Bytes key = hkdfSha256(S, strBytes("wb-receipt-v3-key"), Bytes(), 32);
    const Bytes pt = aeadOpen(key, Bytes(b.begin(), b.begin() + 12), Bytes(b.begin() + 12, b.end()), strBytes(receiptTagOf(S)));
    const json o = json::parse(std::string(pt.begin(), pt.end()));
    if (!o.is_object() || !o.contains("at") || !o["at"].is_number_integer() || o["at"].get<long long>() < 0
        || !o.contains("pub") || !o["pub"].is_string() || !o.contains("sig") || !o["sig"].is_string()) return r;
    const Bytes pub = fromHex(o["pub"].get<std::string>()), sig = fromHex(o["sig"].get<std::string>());
    const long long at = o["at"].get<long long>();
    if (!ecdsaVerify(pub, receiptSigDigest(formId, cid, at), sig)) return r;
    const Bytes h = sha256(pub);
    r.ok = true; r.at = at; r.by = "0x" + toHex(h.data(), 32).substr(24, 40);
    return r;
} catch (...) { return ReceiptProof{}; }
inline json decoyReceiptEntry() {
    Bytes t(32), s(kReceiptProofBytes);
    if (RAND_bytes(t.data(), 32) != 1 || RAND_bytes(s.data(), (int)s.size()) != 1) throw std::runtime_error("the random number generator failed");
    return json({{"t", toHex(t)}, {"s", toHex(s)}});
}

} // namespace whisperbox
