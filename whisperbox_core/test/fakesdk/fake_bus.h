#pragma once
// In-process stand-in for the Waku fleet + loam_core (test-only).
#include "logos_module_context.h"
#include "logos_lp_client.h"
#include <QCoreApplication>
#include <QTimer>
#include <map>
#include <chrono>
#include <set>
#include <memory>
#include <openssl/evp.h>

struct FakeNode {
    // Monotonic serial: queued deliveries carry it and re-check that the node is still on
    // the bus, so a peer stopped mid-flight (restart tests) never gets a dangling call.
    long serial = nextSerial();
    static long nextSerial() { static long n = 0; return ++n; }
    std::string name;
    bool created = false, up = false, online = true, subscribed = false, channel = false;
    int starts = 0;   // start() calls (a second start on a shared node is a bug)
    int failStarts = 0;   // the next N start() calls fail (a transient loam_core error, FR-14)
    std::string senderId;
    std::set<std::string> joined;
    // ADR 0021: loamInstalled=false = no loam_core in this Basecamp (its status call answers empty);
    // the core then goes direct and these raw delivery_module event handlers are its receive path
    bool loamInstalled = true;
    std::string loamStatus;   // non-empty: loam_core's status() answers this (e.g. "Transport error: ...")
    std::string createCfg;    // the last createNode config a direct transport sent
    int failSends = 0;        // the next N sends fail asynchronously (RLN, oversize, disconnected: audit W2-10)
    std::vector<std::pair<std::string, logos::RawFn>> raw;
    void fireRaw(const std::string& ev, const nlohmann::json& args) { for (auto& h : raw) if (h.first == ev) h.second(args); }
    FakeLoamCore::RxFn onRx;
    FakeLoamCore::StatusFn onStatus;
    long rx = 0, tx = 0;
};

struct FakeBus {
    std::vector<FakeNode*> nodes;
    long dropped = 0;
    long long tsNs = 0;   // the network timestamp every frame carries (ns, 0 = none), as loam_core >= 0.8.0
    static FakeBus& get() { static FakeBus b; return b; }
    static std::string b64(const std::string& s) {
        std::string out(4 * ((s.size() + 2) / 3) + 1, '\0');
        int n = EVP_EncodeBlock((unsigned char*)out.data(), (const unsigned char*)s.data(), (int)s.size());
        out.resize(n); return out;
    }
    static void later(std::function<void()> fn) { QTimer::singleShot(0, QCoreApplication::instance(), fn); }
    FakeNode* alive(long serial) {
        for (FakeNode* n : nodes) if (n->serial == serial) return n;
        return nullptr;
    }
    // A frame on a topic: every OTHER node that joined it gets it (SDS drops frames carrying the
    // receiver's own senderId). relay() is what tests use to inject a frame "from the network".
    void deliver(FakeNode* from, const std::string& topic, const std::string& raw, bool selfToo) {
        if (from && !from->online) { dropped++; return; }
        // Store keeps what was published (by wall clock, as a fleet Store node stamps arrivals)
        store.push_back(Stored{topic, raw, (long long)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count()});
        std::string sid = from ? from->senderId : std::string("net");
        for (FakeNode* n : nodes) {
            if ((n == from && !selfToo) || !n->up || !n->online || (!n->onRx && n->raw.empty()) || !n->joined.count(topic)) continue;
            if (from && n->senderId == from->senderId) { dropped++; continue; }
            long serial = n->serial;
            long long ts = tsNs;
            later([serial, topic, sid, raw, ts] {
                FakeNode* nn = FakeBus::get().alive(serial);
                if (!nn || !nn->online) return;
                if (nn->onRx) { nn->rx++; auto fn = nn->onRx; fn(topic, sid, b64(raw), ts); return; }
                // direct: delivery_module's messageReceived [hash, contentTopic, payload bytes, source, ts]
                nlohmann::json bytes = nlohmann::json::array();
                for (unsigned char c : b64(raw)) bytes.push_back((int)c);
                nn->rx++; nn->fireRaw("messageReceived", nlohmann::json::array({"0xhash", topic, bytes, "live", (double)ts}));
            });
        }
    }
    void relay(FakeNode* from, const std::string& topic, const std::string& raw) { deliver(from, topic, raw, false); }
    // Store (ADR 0024): every frame sent on a topic is kept with its time; queries page through it.
    struct Stored { std::string topic, raw; long long tsNs; };
    std::vector<Stored> store;
    long long storeRetentionMs = 2LL * 3600 * 1000;   // tests may shorten it
    bool storeDown = false;
    long long storeQueries = 0;
    nlohmann::json storeInject = nlohmann::json::array();   // a malicious Store: messages added to every reply (audit W2-3)
    long oversize = 0;                                       // frames Delivery refused: over 150 KiB on the wire (audit W2-1)
    void channel(FakeNode* from, const std::string& topic, const std::string& raw) {
        // like Delivery: the transport base64s what the app sent once more; over 150 KiB is refused
        if ((raw.size() + 2) / 3 * 4 > 153600) { oversize++; return; }
        deliver(from, topic, raw, false);
    }
};

static inline std::string fakeB64decode(const std::string& in) {
    std::string out(in.size(), '\0');
    int n = EVP_DecodeBlock((unsigned char*)out.data(), (const unsigned char*)in.data(), (int)in.size());
    if (n < 0) return std::string();
    size_t pad = 0; for (size_t i = in.size(); i > 0 && in[i - 1] == '='; i--) pad++;
    out.resize(n - pad); return out;
}
inline void FakeLoamCore::onReceived(RxFn fn) { node->onRx = fn; }
inline void FakeLoamCore::onStatusChanged(StatusFn fn) { node->onStatus = fn; }
inline void FakeLoamCore::setSenderIdAsync(const std::string& id, StrCb cb) { node->senderId = id; FakeBus::later([cb] { cb("{\"ok\":true}"); }); }
inline void FakeLoamCore::startAsync(const std::string&, StrCb cb) {
    // Like loam_core on Basecamp: one node for every app. Starting it again (another app did, or
    // this one restarted) is fine - it just reports Connected.
    long sid = node->serial;
    FakeBus::later([sid, cb] { if (FakeNode* n = FakeBus::get().alive(sid)) {
        if (n->failStarts > 0) { n->failStarts--; cb("{\"ok\":false,\"error\":\"injected start failure\"}"); return; }
        if (!n->up) { n->up = true; n->starts++; }
        cb("{\"ok\":true}");
        if (n->onStatus) { auto fn = n->onStatus; fn("Connected"); } } });
}
inline void FakeLoamCore::statusAsync(StrCb cb) {
    long sid = node->serial;
    FakeBus::later([sid, cb] { FakeNode* n = FakeBus::get().alive(sid);
        if (n && !n->loamInstalled) { cb(""); return; }   // an absent optional module answers empty
        if (n && !n->loamStatus.empty()) { cb(n->loamStatus); return; }
        cb(n && n->up ? "Connected" : "Connecting..."); });
}
// ── delivery_module (direct) ──
static inline void fakeBindRaw(FakeNode* n) {
    auto& p = logos::fakeLpPending();
    for (auto& h : p) n->raw.push_back(std::move(h));
    p.clear();
}
static inline StdLogosResult fakeOk(LogosMap v = LogosMap()) { StdLogosResult r; r.success = true; r.value = std::move(v); return r; }
inline void FakeDelivery::createNodeAsync(const std::string& cfg, Res cb) {
    fakeBindRaw(node);
    node->createCfg = cfg;
    // a direct transport sets no sender id (plain relay); give the fake node its own so the bus's
    // SDS-style self-filter never mistakes two direct nodes for one
    if (node->senderId.empty()) node->senderId = "direct-" + std::to_string(node->serial);
    StdLogosResult r = fakeOk();
    if (node->created) { r.success = false; r.error = "Context already initialized"; }
    node->created = true;
    FakeBus::later([cb, r] { cb(r); });
}
inline void FakeDelivery::startAsync(Res cb) {
    fakeBindRaw(node);
    long sid = node->serial;
    FakeBus::later([sid, cb] { FakeNode* n = FakeBus::get().alive(sid); if (!n) return;
        if (!n->up) { n->up = true; n->starts++; }
        cb(fakeOk());
        n->fireRaw("nodeStarted", nlohmann::json::array({true, "started", 0.0})); });
}
inline void FakeDelivery::stopAsync(Res cb) { node->up = false; FakeBus::later([cb] { cb(fakeOk()); }); }
inline void FakeDelivery::subscribeAsync(const std::string& topic, Res cb) {
    fakeBindRaw(node);
    node->joined.insert(topic); node->subscribed = true;
    FakeBus::later([cb] { cb(fakeOk()); });
}
inline void FakeDelivery::sendAsync(const std::string& topic, const LogosMap& payload, Res cb) {
    // encodeSend: the bytes of base64(what the app sent); the bus carries what the app sent
    std::string text;
    if (payload.is_array()) for (const auto& c : payload) { if (c.is_number_integer()) text.push_back((char)c.get<int>()); }
    else if (payload.is_string()) text = payload.get<std::string>();
    if (node->failSends > 0) { node->failSends--; StdLogosResult r; r.success = false; r.error = "RLN proof generation failed"; FakeBus::later([cb, r] { cb(r); }); return; }
    node->tx++; FakeBus::get().channel(node, topic, fakeB64decode(text));
    FakeBus::later([cb] { cb(fakeOk()); });
}
inline void FakeDelivery::getNodeInfoAsync(const std::string&, Res cb) {
    if (!node) { StdLogosResult r; r.success = false; r.error = "no node"; FakeBus::later([cb, r] { cb(r); }); return; }
    long sid = node->serial;
    FakeBus::later([sid, cb] { FakeNode* n = FakeBus::get().alive(sid); cb(fakeOk(n && n->up ? "libp2p_peers 5\n" : "libp2p_peers 0\n")); });
}
// Store query (ADR 0024): the bus's store, filtered like a fleet Store node; pages of paginationLimit.
inline void FakeDelivery::storeQueryAsync(const std::string& q, const std::string& peer, long long, Res cb) {
    auto& bus = FakeBus::get();
    bus.storeQueries++;
    if (bus.storeDown || peer.empty() || (node && !node->online)) { StdLogosResult r; r.success = false; r.error = "store peer unreachable"; FakeBus::later([cb, r] { cb(r); }); return; }
    nlohmann::json j = nlohmann::json::parse(q, nullptr, false);
    const long long nowNs = (long long)std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    const long long keepFrom = nowNs - bus.storeRetentionMs * 1000000LL;
    std::set<std::string> topics; if (j.contains("contentTopics")) for (const auto& t : j["contentTopics"]) topics.insert(t.get<std::string>());
    const long long from = j.value("timeStart", 0LL), to = j.value("timeEnd", (long long)9e18);
    const size_t limit = j.value("paginationLimit", 100), start = j.contains("paginationCursor") ? std::stoul(j["paginationCursor"].get<std::string>()) : 0;
    nlohmann::json msgs = nlohmann::json::array(); size_t idx = 0, next = 0;
    for (size_t i = 0; i < bus.store.size(); i++) {
        const auto& m = bus.store[i];
        if (!topics.count(m.topic) || m.tsNs < keepFrom || m.tsNs < from || m.tsNs >= to) continue;
        if (idx++ < start) continue;
        if (msgs.size() >= limit) { next = idx - 1; break; }
        msgs.push_back({{"messageHash", "0x" + std::to_string(i)}, {"pubsubTopic", j.value("pubsubTopic", "")},
                        {"message", {{"payload", FakeBus::b64(FakeBus::b64(m.raw))}, {"contentTopic", m.topic}, {"timestamp", (double)m.tsNs}}}});
    }
    for (const auto& x : bus.storeInject) msgs.push_back(x);
    nlohmann::json v = {{"requestId", j.value("requestId", "")}, {"statusCode", 200}, {"statusDesc", "OK"}, {"messages", msgs}};
    if (next) v["paginationCursor"] = std::to_string(next);
    StdLogosResult r = fakeOk(v.dump());
    FakeBus::later([cb, r] { cb(r); });
}
inline void FakeDelivery::getConnectionStatusAsync(Res cb) {
    long sid = node->serial;
    FakeBus::later([sid, cb] { FakeNode* n = FakeBus::get().alive(sid); cb(fakeOk(n && n->up ? "Connected" : "Disconnected")); });
}
inline void FakeLoamCore::joinAsync(const std::string& topic, StrCb cb) {
    if (!node->up) throw std::runtime_error("loam_core: not started");
    node->joined.insert(topic); node->subscribed = node->channel = true;
    FakeBus::later([cb] { cb("{\"ok\":true}"); });
}
inline void FakeLoamCore::sendSealedAsync(const std::string& topic, const std::string& sealedB64, StrCb cb) {
    if (!node->up) throw std::runtime_error("loam_core: not started");
    if (node->failSends > 0) { node->failSends--; FakeBus::later([cb] { cb("{\"ok\":false,\"error\":\"send failed: no RLN proof\"}"); }); return; }
    node->tx++; FakeBus::get().channel(node, topic, fakeB64decode(sealedB64));
    FakeBus::later([cb] { cb("{\"ok\":true}"); });
}
