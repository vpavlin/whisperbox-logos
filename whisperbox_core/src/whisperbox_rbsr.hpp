#pragma once
// whisperbox_rbsr.hpp - catch-up (RBSR v2) over a sorted id index (open-review 2026-11-02, FR-4).
//
// The same messages as logos_sync::catchup::buildFp / respond (loam-sync; fingerprints byte-identical,
// so peers running either agree), but over an index built once per log change: the sorted ids with
// each id's SHA-256 kept. respond() re-sorted and re-hashed the whole id set for every range of every
// incoming frame (2 s per frame at 50,000 ids). Also: bounds must be strictly increasing inside
// (lo, hi], at most kMaxFps ranges per frame, and serve / need lists are capped (the rest comes on the
// peer's next round). Pure: no transport. test/rbsr_parity_test.cpp checks it against catchup.hpp.
#include <nlohmann/json.hpp>
#include <openssl/sha.h>
#include <algorithm>
#include <array>
#include <set>
#include <string>
#include <unordered_set>
#include <vector>

namespace whisperbox {
namespace rbsr {

using json = nlohmann::json;

struct Index {
    std::vector<std::string> ids;                      // sorted, unique
    std::vector<std::array<unsigned char, 32>> hash;   // SHA-256 of each id
    void build(std::vector<std::string> keys) {
        std::sort(keys.begin(), keys.end());
        keys.erase(std::unique(keys.begin(), keys.end()), keys.end());
        ids.clear(); hash.clear(); ids.reserve(keys.size()); hash.reserve(keys.size());
        for (auto& k : keys) {
            if (k.empty()) continue;
            std::array<unsigned char, 32> h;
            SHA256(reinterpret_cast<const unsigned char*>(k.data()), k.size(), h.data());
            ids.push_back(std::move(k)); hash.push_back(h);
        }
    }
    // [i0, i1) of the index: logos_sync::rbsr::fingerprint over those ids
    std::string fp(size_t i0, size_t i1) const {
        unsigned char acc[32] = {0};
        for (size_t i = i0; i < i1; i++) for (int j = 0; j < 32; j++) acc[j] ^= hash[i][j];
        unsigned char buf[36];
        for (int j = 0; j < 32; j++) buf[j] = acc[j];
        uint32_t c = (uint32_t)(i1 - i0);
        buf[32] = (c >> 24) & 0xff; buf[33] = (c >> 16) & 0xff; buf[34] = (c >> 8) & 0xff; buf[35] = c & 0xff;
        unsigned char out[32];
        SHA256(buf, 36, out);
        static const char* hx = "0123456789abcdef";
        std::string s; s.reserve(32);
        for (int j = 0; j < 16; j++) { s.push_back(hx[out[j] >> 4]); s.push_back(hx[out[j] & 0xf]); }
        return s;
    }
    // the index range of ids in (lo, hi]; an absent bound is open
    std::pair<size_t, size_t> range(const std::string& lo, bool hasLo, const std::string& hi, bool hasHi) const {
        size_t i0 = hasLo ? size_t(std::upper_bound(ids.begin(), ids.end(), lo) - ids.begin()) : 0;
        size_t i1 = hasHi ? size_t(std::upper_bound(ids.begin(), ids.end(), hi) - ids.begin()) : ids.size();
        return {i0, std::max(i0, i1)};
    }
    bool has(const std::string& id, size_t i0, size_t i1) const {
        auto it = std::lower_bound(ids.begin() + i0, ids.begin() + i1, id);
        return it != ids.begin() + i1 && *it == id;
    }
};

// catchup::buildFp over index range [i0, i1)
inline json fpMessage(const Index& x, const std::string& from, size_t i0, size_t i1,
                      const std::string& lo, bool hasLo, const std::string& hi, bool hasHi, int buckets = 8) {
    json msg{{"v", 2}, {"t", "fp"}, {"from", from}};
    if (hasLo) msg["lo"] = lo;
    if (hasHi) msg["hi"] = hi;
    json bounds = json::array(), fps = json::array();
    int n = (int)(i1 - i0);
    int k = std::max(1, std::min(buckets, n == 0 ? 1 : n));
    int step = (n + k - 1) / std::max(1, k);
    if (step < 1) step = 1;
    for (int i = 0; i < n || (n == 0 && i == 0); i += step) {
        int end = std::min(n, i + step);
        bool last = (end >= n);
        fps.push_back(x.fp(i0 + std::min(i, n), i0 + end));
        if (!last) bounds.push_back(x.ids[i0 + end - 1]);   // interior boundary
        if (n == 0) break;
    }
    msg["bounds"] = bounds;
    msg["fps"] = fps;
    return msg;
}
// catchup::buildInitial
inline json initialMessage(const Index& x, const std::string& from, int buckets = 8) {
    return fpMessage(x, from, 0, x.ids.size(), "", false, "", false, buckets);
}

struct Limits { size_t maxFps = 16, maxServe = 100, maxNeed = 500; };
struct Step {
    std::vector<json> replies;
    std::vector<std::string> serve;   // ids to publish (at most maxServe)
    size_t serveSkipped = 0;          // more the peer lacks, left for its next round
    bool bad = false;                 // malformed bounds or too many ranges: ignored
};

// catchup::respond, with the limits above. msg passed wellFormedCatchup.
inline Step respond(const Index& x, const json& msg, const std::string& me, Limits lim = {},
                    int threshold = 8, int buckets = 8) {
    Step st;
    if (!msg.is_object()) return st;
    if (msg.value("from", std::string()) == me) return st;   // our own echo
    const std::string t = msg.value("t", std::string());
    const bool hasLo = msg.contains("lo"), hasHi = msg.contains("hi");
    const std::string lo = hasLo && msg["lo"].is_string() ? msg["lo"].get<std::string>() : std::string();
    const std::string hi = hasHi && msg["hi"].is_string() ? msg["hi"].get<std::string>() : std::string();
    auto serve = [&](const std::string& id) {
        if (st.serve.size() >= lim.maxServe) { st.serveSkipped++; return; }
        st.serve.push_back(id);
    };
    if (t == "fp") {
        const auto& bounds = msg["bounds"];
        const auto& fps = msg["fps"];
        if (fps.size() > lim.maxFps || bounds.size() + 1 != fps.size()) { st.bad = true; return st; }
        std::string prev = lo; bool hasPrev = hasLo;
        for (const auto& b : bounds) {
            const std::string& v = b.get_ref<const std::string&>();
            if ((hasPrev && !(v > prev)) || (hasHi && v > hi)) { st.bad = true; return st; }
            prev = v; hasPrev = true;
        }
        const size_t k = fps.size();
        for (size_t i = 0; i < k; i++) {
            const std::string subLo = i == 0 ? lo : bounds[i - 1].get<std::string>();
            const bool subHasLo = i == 0 ? hasLo : true;
            const std::string subHi = i == k - 1 ? hi : bounds[i].get<std::string>();
            const bool subHasHi = i == k - 1 ? hasHi : true;
            auto r = x.range(subLo, subHasLo, subHi, subHasHi);
            if (x.fp(r.first, r.second) == fps[i].get<std::string>()) continue;   // range agrees
            if ((int)(r.second - r.first) <= threshold) {
                json m{{"v", 2}, {"t", "ids"}, {"from", me}};
                if (subHasLo) m["lo"] = subLo;
                if (subHasHi) m["hi"] = subHi;
                json ids = json::array();
                for (size_t j = r.first; j < r.second; j++) ids.push_back(x.ids[j]);
                m["ids"] = ids;
                st.replies.push_back(m);
            } else {
                st.replies.push_back(fpMessage(x, me, r.first, r.second, subLo, subHasLo, subHi, subHasHi, buckets));
            }
        }
    } else if (t == "ids") {
        auto r = x.range(lo, hasLo, hi, hasHi);
        std::unordered_set<std::string> peer;
        for (const auto& v : msg["ids"]) peer.insert(v.get<std::string>());
        for (size_t j = r.first; j < r.second; j++) if (!peer.count(x.ids[j])) serve(x.ids[j]);
        std::set<std::string> want;   // sorted, as respond() sends it
        for (const auto& id : peer) if (!x.has(id, r.first, r.second)) want.insert(id);
        json need = json::array();
        for (const auto& id : want) { if (need.size() >= lim.maxNeed) break; need.push_back(id); }
        if (!need.empty()) st.replies.push_back(json{{"v", 2}, {"t", "need"}, {"from", me}, {"ids", need}});
    } else if (t == "need") {
        for (const auto& v : msg["ids"]) if (x.has(v.get<std::string>(), 0, x.ids.size())) serve(v.get<std::string>());
    }
    return st;
}

} // namespace rbsr
} // namespace whisperbox
