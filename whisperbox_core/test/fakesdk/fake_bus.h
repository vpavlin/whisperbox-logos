#pragma once
// In-process stand-in for the Waku fleet + loam_core (test-only).
#include "logos_module_context.h"
#include <QCoreApplication>
#include <QTimer>
#include <map>
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
    std::string senderId;
    std::set<std::string> joined;
    FakeLoamCore::RxFn onRx;
    FakeLoamCore::StatusFn onStatus;
    long rx = 0, tx = 0;
};

struct FakeBus {
    std::vector<FakeNode*> nodes;
    long dropped = 0;
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
        std::string sid = from ? from->senderId : std::string("net");
        for (FakeNode* n : nodes) {
            if ((n == from && !selfToo) || !n->up || !n->online || !n->onRx || !n->joined.count(topic)) continue;
            if (from && n->senderId == from->senderId) { dropped++; continue; }
            long serial = n->serial;
            later([serial, topic, sid, raw] {
                FakeNode* nn = FakeBus::get().alive(serial);
                if (nn && nn->online && nn->onRx) { nn->rx++; auto fn = nn->onRx; fn(topic, sid, b64(raw), 0); }
            });
        }
    }
    void relay(FakeNode* from, const std::string& topic, const std::string& raw) { deliver(from, topic, raw, false); }
    void channel(FakeNode* from, const std::string& topic, const std::string& raw) { deliver(from, topic, raw, false); }
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
        if (!n->up) { n->up = true; n->starts++; }
        cb("{\"ok\":true}");
        if (n->onStatus) { auto fn = n->onStatus; fn("Connected"); } } });
}
inline void FakeLoamCore::statusAsync(StrCb cb) {
    long sid = node->serial;
    FakeBus::later([sid, cb] { FakeNode* n = FakeBus::get().alive(sid); cb(n && n->up ? "Connected" : "Connecting..."); });
}
inline void FakeLoamCore::joinAsync(const std::string& topic, StrCb cb) {
    if (!node->up) throw std::runtime_error("loam_core: not started");
    node->joined.insert(topic); node->subscribed = node->channel = true;
    FakeBus::later([cb] { cb("{\"ok\":true}"); });
}
inline void FakeLoamCore::sendSealedAsync(const std::string& topic, const std::string& sealedB64, StrCb cb) {
    if (!node->up) throw std::runtime_error("loam_core: not started");
    node->tx++; FakeBus::get().channel(node, topic, fakeB64decode(sealedB64));
    FakeBus::later([cb] { cb("{\"ok\":true}"); });
}
