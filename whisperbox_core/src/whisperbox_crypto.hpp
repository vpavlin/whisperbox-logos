#pragma once
// whisperbox_core — ECIES response sealing (C++/OpenSSL). BYTE-PARITY with
// packages/contract/src/crypto.mjs:
//   ephPriv = 32B (CSPRNG, or explicit for deterministic tests)
//   ephPub  = secp256k1(ephPriv), compressed 33B
//   Sx      = X-coordinate (32B) of the ECDH shared point
//             sender:  ECDH(ephPriv, creatorPub);  creator: ECDH(creatorPriv, ephPub)
//   K       = HKDF-SHA256(ikm=Sx, salt="whisperbox-ecies-v1", info="", L=32)
//   nonce   = 12B CSPRNG, or sha256("whisperbox-nonce-v1|"||ephPriv||creatorPub)[0..12]
//             when deterministic (golden vectors)
//   aad     = creatorPub(33) || ephPub(33)
//   sealed  = 0x01 || ephPub(33) || nonce(12) || ChaCha20-Poly1305(K, nonce, pt, aad) || tag(16)
#include <string>
#include <vector>
#include <cstdint>
#include <stdexcept>
#include <openssl/evp.h>
#include <openssl/ec.h>
#include <openssl/ecdsa.h>
#include <openssl/obj_mac.h>
#include <openssl/bn.h>
#include <openssl/hmac.h>
#include <openssl/kdf.h>
#include <openssl/rand.h>
#include <openssl/sha.h>

namespace whisperbox {

using Bytes = std::vector<uint8_t>;

inline std::string toHex(const uint8_t* b, size_t n) {
    static const char* H = "0123456789abcdef"; std::string s; s.reserve(n * 2);
    for (size_t i = 0; i < n; i++) { s += H[b[i] >> 4]; s += H[b[i] & 15]; }
    return s;
}
inline std::string toHex(const Bytes& b) { return toHex(b.data(), b.size()); }

inline Bytes fromHex(const std::string& s) {
    auto nib = [](char c) -> int {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1; };
    if (s.size() % 2 != 0) return {};
    Bytes out; out.reserve(s.size() / 2);
    for (size_t i = 0; i + 1 < s.size(); i += 2) {
        int hi = nib(s[i]), lo = nib(s[i + 1]);
        if (hi < 0 || lo < 0) return {};
        out.push_back((uint8_t)((hi << 4) | lo));
    }
    return out;
}

inline Bytes sha256(const Bytes& b) { Bytes out(32); SHA256(b.data(), b.size(), out.data()); return out; }
inline Bytes strBytes(const std::string& s) { return Bytes(s.begin(), s.end()); }

inline Bytes hkdfSha256(const Bytes& ikm, const Bytes& salt, const Bytes& info, size_t len) {
    Bytes out(len);
    EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_HKDF, nullptr);
    if (!ctx) throw std::runtime_error("hkdf ctx");
    EVP_PKEY_derive_init(ctx);
    EVP_PKEY_CTX_set_hkdf_md(ctx, EVP_sha256());
    EVP_PKEY_CTX_set1_hkdf_salt(ctx, salt.data(), (int)salt.size());
    EVP_PKEY_CTX_set1_hkdf_key(ctx, ikm.data(), (int)ikm.size());
    EVP_PKEY_CTX_add1_hkdf_info(ctx, info.data(), (int)info.size());
    size_t outlen = len;
    if (EVP_PKEY_derive(ctx, out.data(), &outlen) <= 0) { EVP_PKEY_CTX_free(ctx); throw std::runtime_error("hkdf derive"); }
    EVP_PKEY_CTX_free(ctx); out.resize(outlen); return out;
}

// ── secp256k1 point helpers ───────────────────────────────────────────────────────
inline const EC_GROUP* secpGroup() {
    static EC_GROUP* grp = EC_GROUP_new_by_curve_name(NID_secp256k1);
    return grp;
}

// priv scalar (32B, 1..n-1) → compressed pubkey (33B). Throws on invalid scalar.
inline Bytes pubFromPriv(const Bytes& priv) {
    if (priv.size() != 32) throw std::runtime_error("priv must be 32 bytes");
    const EC_GROUP* grp = secpGroup();
    BN_CTX* ctx = BN_CTX_new();
    BIGNUM* bn = BN_bin2bn(priv.data(), 32, nullptr);
    BIGNUM* order = BN_new();
    EC_GROUP_get_order(grp, order, ctx);
    Bytes pub;
    if (bn && BN_cmp(bn, BN_value_one()) >= 0 && BN_cmp(bn, order) < 0) {
        EC_POINT* pt = EC_POINT_new(grp);
        if (EC_POINT_mul(grp, pt, bn, nullptr, nullptr, ctx) == 1) {
            pub.resize(33);
            if (EC_POINT_point2oct(grp, pt, POINT_CONVERSION_COMPRESSED, pub.data(), 33, ctx) != 33) pub.clear();
        }
        EC_POINT_free(pt);
    }
    BN_free(bn); BN_free(order); BN_CTX_free(ctx);
    if (pub.size() != 33) throw std::runtime_error("invalid secp256k1 scalar");
    return pub;
}

// ECDH shared X-coordinate (32B). priv: 32B scalar; pub: 33B compressed point.
// S = priv · PubPoint (scalar multiplication of the peer's point — NOT priv·G).
inline Bytes ecdhX(const Bytes& priv, const Bytes& pub) {
    if (priv.size() != 32 || pub.size() != 33) throw std::runtime_error("bad ecdh inputs");
    const EC_GROUP* grp = secpGroup();
    BN_CTX* ctx = BN_CTX_new();
    BIGNUM* bn = BN_bin2bn(priv.data(), 32, nullptr);
    EC_POINT* pubPt = EC_POINT_new(grp); // peer's point
    EC_POINT* S = EC_POINT_new(grp);     // shared point
    Bytes out(32, 0);
    if (EC_POINT_oct2point(grp, pubPt, pub.data(), 33, ctx) == 1 &&
        EC_POINT_mul(grp, S, nullptr, pubPt, bn, ctx) == 1) {
        BIGNUM* X = BN_new(); BIGNUM* Y = BN_new();
        if (EC_POINT_get_affine_coordinates(grp, S, X, Y, ctx) == 1) {
            BN_bn2binpad(X, out.data(), 32);
        }
        BN_free(X); BN_free(Y);
    }
    EC_POINT_free(S); EC_POINT_free(pubPt); BN_free(bn); BN_CTX_free(ctx);
    return out;
}

// ── ChaCha20-Poly1305 AEAD (qaku pattern) ─────────────────────────────────────────
inline Bytes aeadSeal(const Bytes& key, const Bytes& nonce, const Bytes& pt, const Bytes& aad) {
    EVP_CIPHER_CTX* c = EVP_CIPHER_CTX_new();
    EVP_EncryptInit_ex(c, EVP_chacha20_poly1305(), nullptr, nullptr, nullptr);
    EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_SET_IVLEN, 12, nullptr);
    EVP_EncryptInit_ex(c, nullptr, nullptr, key.data(), nonce.data());
    int len = 0;
    EVP_EncryptUpdate(c, nullptr, &len, aad.data(), (int)aad.size());
    Bytes ct(pt.size());
    EVP_EncryptUpdate(c, ct.data(), &len, pt.data(), (int)pt.size());
    int total = len;
    EVP_EncryptFinal_ex(c, ct.data() + len, &len); total += len; ct.resize(total);
    Bytes tag(16);
    EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_GET_TAG, 16, tag.data());
    EVP_CIPHER_CTX_free(c);
    Bytes out; out.reserve(ct.size() + 16);
    out.insert(out.end(), ct.begin(), ct.end());
    out.insert(out.end(), tag.begin(), tag.end());
    return out;
}

inline Bytes aeadOpen(const Bytes& key, const Bytes& nonce, const Bytes& ctTag, const Bytes& aad) {
    if (ctTag.size() < 16) throw std::runtime_error("sealed too short");
    Bytes ct(ctTag.begin(), ctTag.end() - 16);
    Bytes tag(ctTag.end() - 16, ctTag.end());
    EVP_CIPHER_CTX* c = EVP_CIPHER_CTX_new();
    EVP_DecryptInit_ex(c, EVP_chacha20_poly1305(), nullptr, nullptr, nullptr);
    EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_SET_IVLEN, 12, nullptr);
    EVP_DecryptInit_ex(c, nullptr, nullptr, key.data(), nonce.data());
    int len = 0;
    EVP_DecryptUpdate(c, nullptr, &len, aad.data(), (int)aad.size());
    Bytes pt(ct.size());
    EVP_DecryptUpdate(c, pt.data(), &len, ct.data(), (int)ct.size());
    int total = len;
    EVP_CIPHER_CTX_ctrl(c, EVP_CTRL_AEAD_SET_TAG, 16, tag.data());
    int ok = EVP_DecryptFinal_ex(c, pt.data() + len, &len); total += len;
    EVP_CIPHER_CTX_free(c);
    if (ok <= 0) throw std::runtime_error("aead tag verification failed");
    pt.resize(total); return pt;
}

// ── ECIES seal / open (format in header comment) ───────────────────────────────────
/** Seal plaintext to a creator. Pass ephPriv (32B) + deterministic=true for
 *  reproducible golden vectors; otherwise CSPRNG ephemeral + random nonce. */
inline Bytes eciesSeal(const Bytes& creatorPub, const Bytes& plaintext,
                       const Bytes* ephPriv = nullptr, bool deterministic = false) {
    if (creatorPub.size() != 33) throw std::runtime_error("creator pub must be 33 bytes");
    Bytes eph = ephPriv ? *ephPriv : Bytes(32);
    if (eph.size() != 32) throw std::runtime_error("ephPriv must be 32 bytes");
    if (!ephPriv) RAND_bytes(eph.data(), 32);
    const Bytes ephPub = pubFromPriv(eph); // throws on invalid scalar

    const Bytes Sx = ecdhX(eph, creatorPub);
    const Bytes K = hkdfSha256(Sx, strBytes("whisperbox-ecies-v1"), {}, 32);
    Bytes nonce;
    if (deterministic) {
        // sha256("whisperbox-nonce-v1|" || ephPriv || creatorPub)[0..12] — ONE hash
        // of the full concatenation (matches crypto.mjs exactly).
        Bytes buf = strBytes("whisperbox-nonce-v1|");
        buf.insert(buf.end(), eph.begin(), eph.end());
        buf.insert(buf.end(), creatorPub.begin(), creatorPub.end());
        Bytes h = sha256(buf);
        nonce.assign(h.begin(), h.begin() + 12);
    } else {
        nonce.resize(12); RAND_bytes(nonce.data(), 12);
    }
    Bytes aad = creatorPub; aad.insert(aad.end(), ephPub.begin(), ephPub.end());

    const Bytes ctTag = aeadSeal(K, nonce, plaintext, aad);
    Bytes out; out.reserve(1 + 33 + 12 + ctTag.size());
    out.push_back(0x01);
    out.insert(out.end(), ephPub.begin(), ephPub.end());
    out.insert(out.end(), nonce.begin(), nonce.end());
    out.insert(out.end(), ctTag.begin(), ctTag.end());
    return out;
}

/** Open a sealed response with the creator's private key. Throws on bad tag. */
inline Bytes eciesOpen(const Bytes& creatorPriv, const Bytes& sealed) {
    if (sealed.size() < 1 + 33 + 12 + 16) throw std::runtime_error("sealed too short");
    if (sealed[0] != 0x01) throw std::runtime_error("unknown seal version");
    Bytes ephPub(sealed.begin() + 1, sealed.begin() + 34);
    Bytes nonce(sealed.begin() + 34, sealed.begin() + 46);
    Bytes ctTag(sealed.begin() + 46, sealed.end());

    const Bytes creatorPub = pubFromPriv(creatorPriv);
    const Bytes Sx = ecdhX(creatorPriv, ephPub); // symmetric — same shared point
    const Bytes K = hkdfSha256(Sx, strBytes("whisperbox-ecies-v1"), {}, 32);
    Bytes aad = creatorPub; aad.insert(aad.end(), ephPub.begin(), ephPub.end());

    return aeadOpen(K, nonce, ctTag, aad);
}

} // namespace whisperbox
