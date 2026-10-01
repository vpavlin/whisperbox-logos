#pragma once
// In-process stand-in for the Waku fleet + delivery_module (test-only).
#include "logos_module_context.h"
#include <QCoreApplication>
#include <QTimer>
#include <map>
#include <memory>
#include <openssl/evp.h>

struct FakeNode {
    // Monotonic serial: queued deliveries carry it and re-check that the node is still on
    // the bus, so a peer stopped mid-flight (restart tests) never gets a dangling call.
    long serial = nextSerial();
    static long nextSerial() { static long n = 0; return ++n; }
    std::string name;
    bool created = false, up = false, online = true, subscribed = false, channel = false;
    std::string senderId;
    FakeDeliveryModule::MsgFn onMsg, onCh;
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
    // Receive wrapping like delivery 0.1.3+: {"_bytes": base64(raw)}.
    static LogosMap wrap(const std::string& raw) { return LogosMap{{"_bytes", b64(raw)}}; }
    void relay(FakeNode* from, const std::string& topic, const std::string& raw) {
        if (!from->online) { dropped++; return; }
        for (FakeNode* n : nodes) {
            if (!n->up || !n->online || !n->subscribed || !n->onMsg) continue;
            long sid = n->serial;
            later([sid, topic, raw] {
                FakeNode* nn = FakeBus::get().alive(sid);
                if (nn && nn->online && nn->onMsg) { nn->rx++; auto fn = nn->onMsg; fn("hash", topic, wrap(raw), 0); }
            });
        }
    }
    void channel(FakeNode* from, const std::string& chId, const std::string& raw) {
        if (!from->online) { dropped++; return; }
        for (FakeNode* n : nodes) {
            // SDS: a node never delivers frames carrying its OWN senderId.
            if (n == from || !n->up || !n->online || !n->channel || !n->onCh) continue;
            if (n->senderId == from->senderId) { dropped++; continue; }
            long serial = n->serial; std::string sid = from->senderId;
            later([serial, chId, sid, raw] {
                FakeNode* nn = FakeBus::get().alive(serial);
                if (nn && nn->online && nn->onCh) { nn->rx++; auto fn = nn->onCh; fn(chId, sid, wrap(raw), 0); }
            });
        }
    }
};

inline bool FakeDeliveryModule::onMessageReceived(MsgFn fn) { node->onMsg = fn; return true; }
inline bool FakeDeliveryModule::onChannelMessageReceived(MsgFn fn) { node->onCh = fn; return true; }
inline void FakeDeliveryModule::createNodeAsync(const std::string&, std::function<void(StdLogosResult)> cb) {
    long sid = node->serial; FakeBus::later([sid, cb] { if (FakeNode* n = FakeBus::get().alive(sid)) { n->created = true; cb(StdLogosResult{}); } });
}
inline void FakeDeliveryModule::startAsync(std::function<void(StdLogosResult)> cb) {
    long sid = node->serial; FakeBus::later([sid, cb] { if (FakeNode* n = FakeBus::get().alive(sid)) { n->up = true; cb(StdLogosResult{}); } });
}
inline void FakeDeliveryModule::subscribeAsync(const std::string&, std::function<void(StdLogosResult)> cb) {
    if (!node->up) throw std::runtime_error("no provider registered");
    node->subscribed = true; FakeBus::later([cb] { cb(StdLogosResult{}); });
}
inline void FakeDeliveryModule::channelCreateAsync(const std::string&, const std::string&, const std::string& senderId, std::function<void(StdLogosResult)> cb) {
    if (!node->up) throw std::runtime_error("no provider registered");
    node->channel = true; node->senderId = senderId; FakeBus::later([cb] { cb(StdLogosResult{}); });
}
inline void FakeDeliveryModule::channelSendAsync(const std::string& chId, const LogosMap& payload, std::function<void(StdLogosResult)> cb) {
    if (!node->up) throw std::runtime_error("no provider registered");
    std::string raw;
    if (payload.is_array()) { for (auto& c : payload) raw.push_back((char)c.get<int>()); }
    else if (payload.is_string()) raw = payload.get<std::string>();
    else throw std::runtime_error("bad payload repr");
    node->tx++; FakeBus::get().channel(node, chId, raw); FakeBus::later([cb] { cb(StdLogosResult{}); });
}
inline void FakeDeliveryModule::sendAsync(const std::string& topic, const std::vector<uint8_t>& raw, std::function<void(StdLogosResult)> cb) {
    if (!node->up) throw std::runtime_error("no provider registered");
    node->tx++; FakeBus::get().relay(node, topic, std::string(raw.begin(), raw.end())); FakeBus::later([cb] { cb(StdLogosResult{}); });
}
