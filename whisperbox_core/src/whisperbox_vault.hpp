#pragma once
// whisperbox_vault.hpp - an optional passphrase over the identity key and the local private files
// (open-review 2026-11-03, FR-13).
//
// Every Basecamp module runs as the same OS user, so 0600 files don't keep one module out of another's
// data. With a passphrase set, identity.json holds the private key sealed with
// ChaCha20-Poly1305 under scrypt(passphrase), and my_answers.json / drafts.json are sealed under a key
// derived from the identity. Until the user unlocks, the core has no identity: it doesn't sign, send
// or decrypt. No passphrase = the files stay as before (plaintext, 0600).
//
//   identity.json v2: {"v":2,"address","pubHex","kdf":{"alg":"scrypt","N","r","p","salt"},"nonce","ct"}
//                     ct = AEAD(scrypt key, nonce, privHex, aad "whisperbox-identity-v2|<address>")
//   private file:     "WBENC1:" + hex(nonce(12) || AEAD(localKey, nonce, text, aad "whisperbox-local-v1"))
//                     localKey = HKDF-SHA256(identity priv, "whisperbox-local-v1", "files")
#include "whisperbox_crypto.hpp"
#include <nlohmann/json.hpp>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <stdexcept>
#include <string>

namespace whisperbox {
namespace vault {

using json = nlohmann::json;
inline constexpr uint64_t kN = 1u << 15, kR = 8, kP = 1;   // ~32 MiB, ~0.1-0.3 s
inline constexpr size_t kMinPassphrase = 8;
inline const std::string kLocalPrefix = "WBENC1:";

inline Bytes randomBytes(size_t n) {
    Bytes b(n);
    if (RAND_bytes(b.data(), (int)n) != 1) throw std::runtime_error("the random number generator failed");
    return b;
}
inline Bytes passKey(const std::string& pass, const Bytes& salt, uint64_t N = kN, uint64_t r = kR, uint64_t p = kP) {
    if (N > (1u << 20) || r > 16 || p > 4) throw std::runtime_error("scrypt parameters out of range");
    Bytes key(32);
    if (EVP_PBE_scrypt(pass.data(), pass.size(), salt.data(), salt.size(), N, r, p, 256ull << 20, key.data(), key.size()) != 1)
        throw std::runtime_error("scrypt failed");
    return key;
}
// the sealed identity file; key = passKey(pass, salt) (kept by the caller while unlocked)
inline json sealIdentity(const Bytes& priv, const std::string& address, const std::string& pubHex, const Bytes& key, const Bytes& salt) {
    const Bytes nonce = randomBytes(12);
    const std::string privHex = toHex(priv);
    const std::string aad = "whisperbox-identity-v2|" + address;
    json o = {{"v", 2}, {"address", address}, {"pubHex", pubHex},
              {"kdf", {{"alg", "scrypt"}, {"N", kN}, {"r", kR}, {"p", kP}, {"salt", toHex(salt)}}},
              {"nonce", toHex(nonce)}, {"ct", toHex(aeadSeal(key, nonce, strBytes(privHex), strBytes(aad)))}};
    return o;
}
inline bool isSealedIdentity(const json& o) { return o.is_object() && o.value("v", 0) == 2 && o.contains("ct") && o.contains("kdf"); }
// the key for pass and this file's salt / parameters
inline Bytes keyFor(const json& o, const std::string& pass) {
    const json& k = o.at("kdf");
    return passKey(pass, fromHex(k.at("salt").get<std::string>()), k.at("N").get<uint64_t>(), k.at("r").get<uint64_t>(), k.at("p").get<uint64_t>());
}
// the private key; throws on a wrong key (passphrase)
inline Bytes openIdentity(const json& o, const Bytes& key) {
    const std::string aad = "whisperbox-identity-v2|" + o.at("address").get<std::string>();
    const Bytes pt = aeadOpen(key, fromHex(o.at("nonce").get<std::string>()), fromHex(o.at("ct").get<std::string>()), strBytes(aad));
    return fromHex(std::string(pt.begin(), pt.end()));
}
inline Bytes localKey(const Bytes& identityPriv) {
    return hkdfSha256(identityPriv, strBytes("whisperbox-local-v1"), strBytes("files"), 32);
}
inline std::string sealLocal(const Bytes& key, const std::string& text) {
    const Bytes nonce = randomBytes(12);
    Bytes out = nonce;
    const Bytes ct = aeadSeal(key, nonce, strBytes(text), strBytes("whisperbox-local-v1"));
    out.insert(out.end(), ct.begin(), ct.end());
    return kLocalPrefix + toHex(out);
}
inline bool isSealedLocal(const std::string& text) { return text.rfind(kLocalPrefix, 0) == 0; }
inline std::string openLocal(const Bytes& key, const std::string& text) {
    const Bytes all = fromHex(text.substr(kLocalPrefix.size()));
    if (all.size() < 12 + 16) throw std::runtime_error("sealed file too short");
    const Bytes nonce(all.begin(), all.begin() + 12), ct(all.begin() + 12, all.end());
    const Bytes pt = aeadOpen(key, nonce, ct, strBytes("whisperbox-local-v1"));
    return std::string(pt.begin(), pt.end());
}

} // namespace vault
} // namespace whisperbox
